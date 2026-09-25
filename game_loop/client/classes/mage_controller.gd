## mage_controller.gd
## Controlador del Mago (combatStyle = CLINCH).
## Gestiona el estado visual del casteo (barra de progreso) y envía
## CAST_START / CAST_CANCEL al servidor.
## El servidor valida LOS, distancia (2-15 m) y gestiona el cast timer real.
##
## Spec: GAMELOOP_TECHNICAL_SPEC.md §3.3

class_name MageController
extends Node

# ---------------------------------------------------------------------------
# Señales
# ---------------------------------------------------------------------------

signal cast_started(skill_id: String, cast_ms: int)
signal cast_interrupted()
signal cast_completed(skill_id: String)

# ---------------------------------------------------------------------------
# Dependencias
# ---------------------------------------------------------------------------

@export var intent_sender: ActionIntentSender
@export var player_fsm: PlayerStateMachine
@export var camera: Camera3D

# ---------------------------------------------------------------------------
# Configuración
# ---------------------------------------------------------------------------

const SLOT_FIREBALL:    int = 0
const SLOT_FROSTBOLT:   int = 1
const SLOT_NOVA:        int = 2   # AOE

## Tiempos de casteo visualmente esperados (ms). El servidor tiene los valores
## canónicos; estos son solo para la barra de progreso local.
const CAST_TIMES_MS: Dictionary = {
	SLOT_FIREBALL:  1500,
	SLOT_FROSTBOLT: 2000,
	SLOT_NOVA:      3000,
}

const COOLDOWNS_MS: Dictionary = {
	SLOT_FIREBALL:  3000,
	SLOT_FROSTBOLT: 4000,
	SLOT_NOVA:      12000,
}

# ---------------------------------------------------------------------------
# Estado de casteo local (solo visual)
# ---------------------------------------------------------------------------

var _casting: bool           = false
var _cast_slot: int          = -1
var _cast_start_ms: int      = 0
var _cast_duration_ms: int   = 0
var _cast_target_id: int     = -1
var _cast_target_pos: Vector3 = Vector3.ZERO

# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------

func on_skill_tap(slot: int, screen_pos: Vector2) -> void:
	if not _ready_to_act(slot):
		return
	if _casting:
		return  # ya está casteando; el servidor también lo rechazaría

	var target := _raycast_target(screen_pos)
	if target.is_empty():
		return

	_cast_slot       = slot
	_cast_target_id  = target["entity_id"]
	_cast_target_pos = target["world_pos"]

	# Iniciar barra de casteo visual (optimista)
	_start_cast_visual(slot)

	# Notificar al servidor — el servidor arranca su propio cast timer
	intent_sender.send_cast_start(_cast_target_id, _cast_target_pos, slot)


func on_cancel_cast() -> void:
	if not _casting:
		return
	_cancel_cast_visual()
	intent_sender.send_cast_cancel()


## El servidor puede interrumpir el casteo (daño recibido).
## Llamado desde network_manager via SKILL_RESULT con code CAST_INTERRUPTED.
func on_server_interrupted() -> void:
	_cancel_cast_visual()
	emit_signal("cast_interrupted")

# ---------------------------------------------------------------------------
# Update loop — progresa la barra visual de casteo
# ---------------------------------------------------------------------------

func update(_delta: float) -> void:
	if not _casting:
		return
	var elapsed := Time.get_ticks_msec() - _cast_start_ms
	var progress := float(elapsed) / float(_cast_duration_ms)
	_update_cast_bar(clampf(progress, 0.0, 1.0))

	# La barra llega al 100 % pero el cliente NO resuelve el casteo.
	# Solo muestra animación de "esperando confirmación del servidor".
	if progress >= 1.0:
		_show_cast_pending()


func on_skill_result(result: Dictionary) -> void:
	var code: int = result.get("result_code", 0)
	match code:
		0x01:  # HIT (casteo completado y aplicado)
			_finish_cast_visual()
			player_fsm.set_local_cooldown(_cast_slot, COOLDOWNS_MS.get(_cast_slot, 0))
			emit_signal("cast_completed", _slot_to_id(_cast_slot))
			_casting = false
		0x04:  # CAST_INTERRUPTED
			on_server_interrupted()
		0x06:  # INVALID (LOS fallido, fuera de rango, etc.)
			_cancel_cast_visual()
			_casting = false

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _ready_to_act(slot: int) -> bool:
	return player_fsm != null \
		and player_fsm.can_act() \
		and not player_fsm.is_skill_on_cooldown(slot)


func _raycast_target(screen_pos: Vector2) -> Dictionary:
	if camera == null:
		return {}
	var ray_from := camera.project_ray_origin(screen_pos)
	# Rango máximo visual 16 m (servidor acepta hasta 15 m)
	var ray_to   := ray_from + camera.project_ray_normal(screen_pos) * 16.0
	var space    := camera.get_world_3d().direct_space_state
	var query    := PhysicsRayQueryParameters3D.create(ray_from, ray_to)
	query.collision_mask = 0b0010
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return {}
	var collider: Object = hit["collider"]
	if collider == null or not collider.has_meta("entity_id"):
		return {}
	return {
		"entity_id": int(collider.get_meta("entity_id")),
		"world_pos": hit["position"],
	}


func _start_cast_visual(slot: int) -> void:
	_casting          = true
	_cast_start_ms    = Time.get_ticks_msec()
	_cast_duration_ms = CAST_TIMES_MS.get(slot, 1500)
	emit_signal("cast_started", _slot_to_id(slot), _cast_duration_ms)


func _cancel_cast_visual() -> void:
	_casting = false
	_update_cast_bar(0.0)


func _finish_cast_visual() -> void:
	_casting = false
	_update_cast_bar(1.0)


func _update_cast_bar(progress: float) -> void:
	# Notificar a la UI (HUD) — implementación de UI pendiente
	pass


func _show_cast_pending() -> void:
	pass


func _slot_to_id(slot: int) -> String:
	match slot:
		SLOT_FIREBALL:  return "mage_fireball_01"
		SLOT_FROSTBOLT: return "mage_frostbolt_01"
		SLOT_NOVA:      return "mage_nova_01"
		_:              return "mage_unknown"
