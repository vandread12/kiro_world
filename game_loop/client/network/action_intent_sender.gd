## action_intent_sender.gd
## Serializa y envía ActionIntent (0x05) al servidor autoritativo por UDP.
## El cliente NUNCA calcula si el golpe fue Hit o Miss; solo comunica la intención.
##
## Spec: GAMELOOP_TECHNICAL_SPEC.md §5.1
## Formato binario (30 bytes fijos):
##   0-1  PacketID    uint16_le
##   2    PacketType  0x05
##   3    PlayerID_lo uint8
##   4    Tick        uint8  (módulo 256)
##   5    ActionType  uint8
##   6-7  TargetID    uint16_le
##   8-11 TargetX     int32_le  (cm, relativo al CloudAnchor)
##  12-15 TargetY     int32_le
##  16-19 TargetZ     int32_le
##  20    SkillSlot   uint8
##  21-22 ForwardVecX int16_le  (q15: valor × 32767)
##  23-24 ForwardVecY int16_le
##  25-26 ForwardVecZ int16_le
##  27-29 reserved    3 bytes cero

class_name ActionIntentSender
extends Node

# ---------------------------------------------------------------------------
# Constantes de tipo de acción (spec §5.1)
# ---------------------------------------------------------------------------

enum ActionType {
	MELEE_STRIKE  = 0x01,
	CAST_START    = 0x02,
	CAST_CANCEL   = 0x03,
	HEAL_APPLY    = 0x04,
	REVIVE_APPLY  = 0x05,
	SKILL_USE     = 0x06,
}

const PACKET_TYPE_ACTION_INTENT: int = 0x05
const PACKET_SIZE: int = 30
const Q15_SCALE: float = 32767.0

# ---------------------------------------------------------------------------
# Dependencias
# ---------------------------------------------------------------------------

# udp_socket es PacketPeerUDP (RefCounted): no se puede @export.
# Se asigna desde network_manager tras crear el socket.
var udp_socket: PacketPeerUDP
var player_fsm: PlayerStateMachine  # asignado desde el ensamblado de la escena
@export var cloud_anchor_node: Node3D  # CloudAnchorNode del spec Multiplayer (sí es Node, exportable)

var _packet_id: int = 0  # secuencia uint16, wraps at 65535
var _local_player_id: int = 0
var _current_tick: int = 0  # incrementado por world_manager cada tick (30 Hz)

# ---------------------------------------------------------------------------
# API pública — una función por tipo de acción
# ---------------------------------------------------------------------------

## Intento de golpe melee (Guerrero / STRIKING).
## El servidor valida distancia < 2 m + lag compensation.
func send_melee_strike(target_id: int, target_pos_world: Vector3) -> void:
	if not _can_send():
		return
	var pos_cm := _world_to_anchor_cm(target_pos_world)
	_send_intent(ActionType.MELEE_STRIKE, target_id, pos_cm, 0, Vector3.ZERO)


## Inicio de casteo (Mago / CLINCH).
## El servidor valida LOS y arranca el cast timer.
func send_cast_start(target_id: int, target_pos_world: Vector3, skill_slot: int) -> void:
	if not _can_send():
		return
	var pos_cm := _world_to_anchor_cm(target_pos_world)
	_send_intent(ActionType.CAST_START, target_id, pos_cm, skill_slot, Vector3.ZERO)


## Cancelación de casteo (Mago).
func send_cast_cancel() -> void:
	if not _can_send():
		return
	_send_intent(ActionType.CAST_CANCEL, 0, Vector3i.ZERO, 0, Vector3.ZERO)


## Cura aplicada (Healer / GRAPPLE).
## forward_vec: dirección de la cámara del Healer (normalizada en espacio mundo).
## El servidor hace el raycasting real; el cliente solo reporta adónde mira.
func send_heal_apply(skill_slot: int, forward_vec_world: Vector3) -> void:
	if not _can_send():
		return
	_send_intent(ActionType.HEAL_APPLY, 0, Vector3i.ZERO, skill_slot, forward_vec_world)


## Revive aplicado (Healer / GRAPPLE) sobre un aliado DOWNED.
func send_revive_apply(target_id: int, forward_vec_world: Vector3, item_slot: int) -> void:
	if not _can_send():
		return
	_send_intent(ActionType.REVIVE_APPLY, target_id, Vector3i.ZERO, item_slot, forward_vec_world)


## Habilidad activa genérica.
func send_skill_use(target_id: int, target_pos_world: Vector3, skill_slot: int) -> void:
	if not _can_send():
		return
	var pos_cm := _world_to_anchor_cm(target_pos_world)
	_send_intent(ActionType.SKILL_USE, target_id, pos_cm, skill_slot, Vector3.ZERO)

# ---------------------------------------------------------------------------
# Serialización (spec §5.1, 30 bytes fijos)
# ---------------------------------------------------------------------------

func _send_intent(
	action: ActionType,
	target_id: int,
	target_pos_cm: Vector3i,
	skill_slot: int,
	forward_vec: Vector3
) -> void:
	var buf := PackedByteArray()
	buf.resize(PACKET_SIZE)
	buf.fill(0)

	var off := 0

	# Bytes 0-1: PacketID
	buf.encode_u16(off, _packet_id & 0xFFFF)
	off += 2
	_packet_id = (_packet_id + 1) & 0xFFFF

	# Byte 2: PacketType
	buf[off] = PACKET_TYPE_ACTION_INTENT
	off += 1

	# Byte 3: PlayerID_lo
	buf[off] = _local_player_id & 0xFF
	off += 1

	# Byte 4: Tick (módulo 256 para lag compensation)
	buf[off] = _current_tick & 0xFF
	off += 1

	# Byte 5: ActionType
	buf[off] = int(action)
	off += 1

	# Bytes 6-7: TargetID
	buf.encode_u16(off, target_id & 0xFFFF)
	off += 2

	# Bytes 8-19: TargetX/Y/Z (int32_le, cm)
	buf.encode_s32(off, target_pos_cm.x)
	off += 4
	buf.encode_s32(off, target_pos_cm.y)
	off += 4
	buf.encode_s32(off, target_pos_cm.z)
	off += 4

	# Byte 20: SkillSlot
	buf[off] = skill_slot & 0xFF
	off += 1

	# Bytes 21-26: ForwardVec (q15: float [-1,1] → int16)
	buf.encode_s16(off, _f_to_q15(forward_vec.x))
	off += 2
	buf.encode_s16(off, _f_to_q15(forward_vec.y))
	off += 2
	buf.encode_s16(off, _f_to_q15(forward_vec.z))
	off += 2

	# Bytes 27-29: reserved, ya son cero por fill(0)

	assert(off == 27, "Offset final incorrecto antes de reserved")

	if udp_socket and udp_socket.get_available_packet_count() >= 0:
		udp_socket.put_packet(buf)


## Convierte una posición en espacio mundo (metros, Godot) a coordenadas
## relativas al CloudAnchorNode en centímetros (int32).
## Los ejes de Godot son Y-up; los del servidor también (mismo convenio).
func _world_to_anchor_cm(world_pos: Vector3) -> Vector3i:
	if cloud_anchor_node == null:
		push_error("[ActionIntentSender] cloud_anchor_node no asignado")
		return Vector3i.ZERO
	var local_m: Vector3 = cloud_anchor_node.to_local(world_pos)
	return Vector3i(
		int(local_m.x * 100.0),
		int(local_m.y * 100.0),
		int(local_m.z * 100.0),
	)


func _f_to_q15(v: float) -> int:
	return int(clampf(v, -1.0, 1.0) * Q15_SCALE)


func _can_send() -> bool:
	if player_fsm == null:
		return false
	return player_fsm.can_act()

# ---------------------------------------------------------------------------
# Setters llamados desde network_manager / world_manager
# ---------------------------------------------------------------------------

func set_player_id(pid: int) -> void:
	_local_player_id = pid


func set_current_tick(tick: int) -> void:
	_current_tick = tick
