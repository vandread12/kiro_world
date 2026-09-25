## network_manager.gd
## Gestiona la conexión UDP con el servidor autoritativo.
## Recibe paquetes UPDATE (0x01) y SKILL_RESULT (0x06), los desserializa
## y distribuye los eventos a los sistemas del cliente.
##
## Spec: MULTIPLAYER_TECHNICAL_SPEC.md §4 y GAMELOOP_TECHNICAL_SPEC.md §5

class_name NetworkManager
extends Node

# ---------------------------------------------------------------------------
# Tipos de paquete (del spec)
# ---------------------------------------------------------------------------

enum PacketType {
	UPDATE        = 0x01,
	SYNC_REQ      = 0x02,
	SYNC_RESP     = 0x03,
	HEARTBEAT     = 0x04,
	ACTION_INTENT = 0x05,
	SKILL_RESULT  = 0x06,
}

# Eventos de juego embebidos en el cuerpo del paquete UPDATE
enum GameEvent {
	PLAYER_DOWNED    = 0x10,
	PLAYER_REVIVED   = 0x11,
	PLAYER_ELIMINATED = 0x12,
	BOSS_PHASE       = 0x13,
	BOSS_DEFEATED    = 0x14,
	MATCH_RESULT     = 0x15,
}

# ---------------------------------------------------------------------------
# Señales
# ---------------------------------------------------------------------------

signal world_state_received(players: Array, entities: Array)
signal player_downed(player_id: int, timer_abs_ms: int)
signal player_revived(player_id: int, new_hp: int)
signal player_eliminated(player_id: int)
signal boss_phase_changed(phase: int)
signal boss_defeated()
signal match_result_received(won: bool, data: Dictionary)
signal skill_result_received(result: Dictionary)
signal sync_response_received(data: Dictionary)

# ---------------------------------------------------------------------------
# Configuración
# ---------------------------------------------------------------------------

@export var server_ip: String = "127.0.0.1"
@export var server_port: int = 30000
@export var heartbeat_interval_ms: int = 1000

var udp: PacketPeerUDP
var _connected: bool = false
var _last_heartbeat_ms: int = 0
var _server_time_offset_ms: int = 0   # para el reloj del cliente

# Referencia para propagar eventos
@export var player_fsm: PlayerStateMachine
@export var intent_sender: ActionIntentSender

# ---------------------------------------------------------------------------
# Ciclo de vida
# ---------------------------------------------------------------------------

func _ready() -> void:
	udp = PacketPeerUDP.new()
	var err := udp.connect_to_host(server_ip, server_port)
	if err != OK:
		push_error("[NetworkManager] No se pudo conectar a %s:%d" % [server_ip, server_port])
		return
	_connected = true
	intent_sender.udp_socket = udp
	_send_sync_request()


func _process(_delta: float) -> void:
	if not _connected:
		return
	_poll_packets()
	_tick_heartbeat()


func _poll_packets() -> void:
	while udp.get_available_packet_count() > 0:
		var raw := udp.get_packet()
		if raw.size() < 3:
			continue
		_dispatch_packet(raw)


func _tick_heartbeat() -> void:
	var now := Time.get_ticks_msec()
	if now - _last_heartbeat_ms >= heartbeat_interval_ms:
		_send_heartbeat()
		_last_heartbeat_ms = now

# ---------------------------------------------------------------------------
# Deserialización de paquetes entrantes
# ---------------------------------------------------------------------------

func _dispatch_packet(raw: PackedByteArray) -> void:
	var ptype: int = raw[2]
	match ptype:
		PacketType.UPDATE:
			_parse_update(raw)
		PacketType.SYNC_RESP:
			_parse_sync_resp(raw)
		PacketType.SKILL_RESULT:
			_parse_skill_result(raw)
		PacketType.HEARTBEAT:
			_handle_heartbeat_pong(raw)


## UPDATE (0x01): estado del mundo a 30 Hz.
## Spec MULTIPLAYER_TECHNICAL_SPEC.md §4.2
func _parse_update(raw: PackedByteArray) -> void:
	if raw.size() < 10:
		return
	# Cabecera ya parseada (PacketID, Type, PlayerCount, Timestamp, Checksum)
	var player_count: int = raw[3]
	var server_tick: int  = raw.decode_u16(4)
	# (checksum en bytes 6-9: omitimos validación aquí, el servidor la hace)

	var off := 10
	var players := []
	for _i in player_count:
		if off + 20 > raw.size():
			break
		players.append({
			"player_id": raw.decode_u16(off),
			"flags":     raw.decode_u16(off + 2),
			"hp":        raw.decode_u16(off + 4),
			"pos_cm":    Vector3i(
				raw.decode_s32(off + 6),
				raw.decode_s32(off + 10),
				raw.decode_s32(off + 14)
			),
			"rotation":  raw.decode_u16(off + 18),
		})
		off += 20

	# Comprobar si hay eventos de juego embebidos (bloques opcionales al final)
	var entities := []
	while off + 2 <= raw.size():
		var etype: int = raw[off]
		match etype:
			# Entidades normales (EntityID presente)
			0x00:
				if off + 16 > raw.size():
					break
				entities.append({
					"entity_id":   raw.decode_u16(off),
					"pos_cm":      Vector3i(
						raw.decode_s32(off + 2),
						raw.decode_s32(off + 6),
						raw.decode_s32(off + 10)
					),
					"entity_type": raw.decode_u16(off + 14),
				})
				off += 16
			# Eventos embebidos
			GameEvent.PLAYER_DOWNED:
				if off + 11 > raw.size():
					break
				var pid       := raw.decode_u16(off + 1)
				var timer_abs := raw.decode_s64(off + 3) # epoch ms, 8 bytes
				emit_signal("player_downed", pid, timer_abs)
				if player_fsm and pid == intent_sender._local_player_id:
					player_fsm.on_server_downed(timer_abs)
				off += 11
			GameEvent.PLAYER_REVIVED:
				if off + 5 > raw.size():
					break
				var pid    := raw.decode_u16(off + 1)
				var new_hp := raw.decode_u16(off + 3)
				emit_signal("player_revived", pid, new_hp)
				if player_fsm and pid == intent_sender._local_player_id:
					player_fsm.on_server_revived(new_hp)
				off += 5
			GameEvent.PLAYER_ELIMINATED:
				if off + 3 > raw.size():
					break
				var pid := raw.decode_u16(off + 1)
				emit_signal("player_eliminated", pid)
				if player_fsm and pid == intent_sender._local_player_id:
					player_fsm.on_server_eliminated()
				off += 3
			GameEvent.BOSS_PHASE:
				if off + 2 > raw.size():
					break
				emit_signal("boss_phase_changed", int(raw[off + 1]))
				off += 2
			GameEvent.BOSS_DEFEATED:
				emit_signal("boss_defeated")
				off += 1
			GameEvent.MATCH_RESULT:
				if off + 2 > raw.size():
					break
				var won := raw[off + 1] != 0
				emit_signal("match_result_received", won, {})
				off += 2
			_:
				break  # bloque desconocido, detener

	emit_signal("world_state_received", players, entities)
	intent_sender.set_current_tick(server_tick)


## SKILL_RESULT (0x06): respuesta autoritativa a un ActionIntent.
## Spec GAMELOOP_TECHNICAL_SPEC.md §5.3
func _parse_skill_result(raw: PackedByteArray) -> void:
	if raw.size() < 12:
		return
	var result_map := {
		"tick":         raw.decode_u16(4),
		"caster_id":    raw.decode_u16(6),
		"target_id":    raw.decode_u16(8),
		"result_code":  raw[10],
		"value":        raw.decode_u16(11) if raw.size() > 12 else 0,
	}
	emit_signal("skill_result_received", result_map)


## SYNC_RESP (0x03): estado completo tras reconexión.
func _parse_sync_resp(raw: PackedByteArray) -> void:
	# La respuesta es JSON comprimido — simplificado aquí para claridad
	var json_start := 10
	if raw.size() <= json_start:
		return
	var json_bytes := raw.slice(json_start)
	var text := json_bytes.get_string_from_utf8()
	var data: Dictionary = JSON.parse_string(text) if text else {}
	emit_signal("sync_response_received", data)
	if player_fsm and data.has("state"):
		player_fsm.on_server_state_sync(data["state"], data)


func _handle_heartbeat_pong(raw: PackedByteArray) -> void:
	# Calcula el offset de reloj con el timestamp del servidor (bytes 4-11)
	if raw.size() < 12:
		return
	var server_ts: int = raw.decode_s64(4)  # epoch ms del servidor
	var client_now: int = Time.get_ticks_msec()
	# Estimación simplificada: offset = server_ts - client_now
	_server_time_offset_ms = server_ts - client_now
	if player_fsm:
		player_fsm.set_server_clock_offset(_server_time_offset_ms)

# ---------------------------------------------------------------------------
# Paquetes salientes auxiliares
# ---------------------------------------------------------------------------

func _send_sync_request() -> void:
	var buf := PackedByteArray()
	buf.resize(8)
	buf.fill(0)
	buf.encode_u16(0, 0)           # PacketID = 0
	buf[2] = PacketType.SYNC_REQ
	# Bytes 3-7: cero (reservado)
	udp.put_packet(buf)


func _send_heartbeat() -> void:
	var buf := PackedByteArray()
	buf.resize(12)
	buf.fill(0)
	buf.encode_u16(0, 0)
	buf[2] = PacketType.HEARTBEAT
	buf.encode_s64(4, Time.get_ticks_msec())  # timestamp del cliente
	udp.put_packet(buf)
