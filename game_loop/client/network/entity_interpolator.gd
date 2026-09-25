## entity_interpolator.gd
## Interpola visualmente las posiciones de entidades remotas entre ticks UDP.
## Las posiciones autoritativas llegan a 30 Hz (33.3 ms); la interpolación
## hace que el movimiento sea fluido a cualquier FPS del dispositivo.
##
## Spec: MULTIPLAYER_TECHNICAL_SPEC.md §3 (topología de nodos)
## Conversión: posición en cm (int32) → metros (float) para Godot.

class_name EntityInterpolator
extends Node

# ---------------------------------------------------------------------------
# Configuración
# ---------------------------------------------------------------------------

## Tiempo entre ticks del servidor (ms). Debe coincidir con el tick rate del spec.
const SERVER_TICK_MS: float = 33.3

## Suavizado máximo de interpolación (segundos atrás respecto al último tick).
const INTERP_DELAY_S: float = SERVER_TICK_MS * 2.0 / 1000.0  # 2 ticks de buffer

# ---------------------------------------------------------------------------
# Estado por entidad
# ---------------------------------------------------------------------------

# { entity_id: { prev_pos, prev_rot, next_pos, next_rot, timestamp_ms } }
var _states: Dictionary = {}

# Nodo raíz donde viven las entidades remotas (CloudAnchorNode en Godot)
@export var cloud_anchor_node: Node3D

# ---------------------------------------------------------------------------
# API pública
# ---------------------------------------------------------------------------

## Llamado por network_manager cada vez que llega un paquete UPDATE.
func on_world_state(players: Array, entities: Array) -> void:
	var now_ms := Time.get_ticks_msec()

	for p in players:
		_record_state(
			"player_%d" % p["player_id"],
			p["pos_cm"],
			p["rotation"],
			now_ms
		)

	for e in entities:
		_record_state(
			"entity_%d" % e["entity_id"],
			e["pos_cm"],
			0,
			now_ms
		)


func _record_state(key: String, pos_cm: Vector3i, rot_deg: int, ts_ms: int) -> void:
	var pos_m := Vector3(pos_cm.x, pos_cm.y, pos_cm.z) * 0.01

	if _states.has(key):
		var s: Dictionary = _states[key]
		s["prev_pos"] = s["next_pos"]
		s["prev_rot"] = s["next_rot"]
		s["next_pos"] = pos_m
		s["next_rot"] = rot_deg
		s["timestamp_ms"] = ts_ms
	else:
		_states[key] = {
			"prev_pos": pos_m,
			"prev_rot": rot_deg,
			"next_pos": pos_m,
			"next_rot": rot_deg,
			"timestamp_ms": ts_ms,
		}

# ---------------------------------------------------------------------------
# Update loop — interpola cada frame
# ---------------------------------------------------------------------------

func update(delta: float) -> void:
	if cloud_anchor_node == null:
		return

	var now_ms := Time.get_ticks_msec()

	for key in _states:
		var s: Dictionary = _states[key]
		var age_ms: float = float(now_ms - s["timestamp_ms"])
		# t = qué fracción del intervalo entre prev y next ya ha pasado
		var t: float = clampf(age_ms / SERVER_TICK_MS, 0.0, 1.5)

		# Indexar un Dictionary devuelve Variant: hay que tipar explícitamente.
		var prev_pos: Vector3 = s["prev_pos"]
		var next_pos: Vector3 = s["next_pos"]
		var interp_pos: Vector3 = prev_pos.lerp(next_pos, t)
		var interp_rot: float = lerpf(float(s["prev_rot"]), float(s["next_rot"]), t)

		_apply_to_node(key, interp_pos, interp_rot)


func _apply_to_node(key: String, pos_m: Vector3, rot_deg: float) -> void:
	# Busca el nodo hijo del CloudAnchorNode que tiene el metadato "interp_key"
	# (asignado al instanciar RemotePlayer_N o EnemyBot_N)
	if cloud_anchor_node == null:
		return

	for child in cloud_anchor_node.find_children("*", "Node3D", true, false):
		if child.has_meta("interp_key") and child.get_meta("interp_key") == key:
			child.position = pos_m
			child.rotation_degrees.y = rot_deg
			return

# ---------------------------------------------------------------------------
# Gestión de entidades dinámicas
# ---------------------------------------------------------------------------

## Llamado cuando el servidor anuncia una entidad nueva (ENTITY_SPAWN).
func register_entity(key: String, initial_pos_cm: Vector3i) -> void:
	var pos_m := Vector3(initial_pos_cm.x, initial_pos_cm.y, initial_pos_cm.z) * 0.01
	_states[key] = {
		"prev_pos": pos_m,
		"prev_rot": 0,
		"next_pos": pos_m,
		"next_rot": 0,
		"timestamp_ms": Time.get_ticks_msec(),
	}


## Llamado cuando una entidad abandona la partida.
func unregister_entity(key: String) -> void:
	_states.erase(key)
