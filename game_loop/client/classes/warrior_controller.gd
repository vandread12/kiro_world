## warrior_controller.gd
## Controlador del Guerrero (combatStyle = STRIKING).
## Solo captura input y envía ActionIntent al servidor.
## El servidor valida la distancia (< 2 m) y calcula el daño.
##
## Spec: GAMELOOP_TECHNICAL_SPEC.md §3.2

class_name WarriorController
extends Node

# ---------------------------------------------------------------------------
# Dependencias
# ---------------------------------------------------------------------------

@export var intent_sender: ActionIntentSender
@export var player_fsm: PlayerStateMachine
@export var camera: Camera3D
@export var cloud_anchor_node: Node3D

# ---------------------------------------------------------------------------
# Configuración (refleja constantes del servidor para feedback visual)
# ---------------------------------------------------------------------------

## Rango visual de melee. El servidor usa 2.3 m con lag comp; aquí usamos 2.5 m
## para mostrar el reticle antes de que el servidor diga MISS.
const MELEE_RANGE_VISUAL_M: float = 2.5

## Índices de slots del loadout (0-7, spec §5.1)
const SLOT_MELEE_BASIC:  int = 0
const SLOT_MELEE_HEAVY:  int = 1
const SLOT_TAUNT:        int = 2

## Duración visual del cooldown por slot (ms). El servidor puede diferir;
## en ese caso el SKILL_RESULT autoritativo sobrescribe.
const COOLDOWNS_MS: Dictionary = {
	SLOT_MELEE_BASIC: 800,
	SLOT_MELEE_HEAVY: 2000,
	SLOT_TAUNT:       8000,
}

# ---------------------------------------------------------------------------
# Estado local
# ---------------------------------------------------------------------------

var _target_entity_id: int = -1
var _target_world_pos: Vector3 = Vector3.ZERO

# ---------------------------------------------------------------------------
# Input — llamado desde world_manager._input o un InputHandler dedicado
# ---------------------------------------------------------------------------

## Tap en pantalla: intento de golpe básico.
func on_tap(screen_pos: Vector2) -> void:
	if not _ready_to_act(SLOT_MELEE_BASIC):
		return

	var target := _raycast_target(screen_pos)
	if target.is_empty():
		return

	_target_entity_id  = target["entity_id"]
	_target_world_pos  = target["world_pos"]

	# Feedback visual optimista (animación, sonido)
	_play_swing_anim("melee_basic")

	# Enviar intento al servidor — el servidor decide HIT o MISS
	intent_sender.send_melee_strike(_target_entity_id, _target_world_pos)
	player_fsm.set_local_cooldown(SLOT_MELEE_BASIC, COOLDOWNS_MS[SLOT_MELEE_BASIC])


## Tap largo: golpe pesado.
func on_long_press(screen_pos: Vector2) -> void:
	if not _ready_to_act(SLOT_MELEE_HEAVY):
		return

	var target := _raycast_target(screen_pos)
	if target.is_empty():
		return

	_play_swing_anim("melee_heavy")
	intent_sender.send_melee_strike(target["entity_id"], target["world_pos"])
	player_fsm.set_local_cooldown(SLOT_MELEE_HEAVY, COOLDOWNS_MS[SLOT_MELEE_HEAVY])


## Botón de Taunt.
func on_taunt() -> void:
	if not _ready_to_act(SLOT_TAUNT):
		return
	intent_sender.send_skill_use(
		_target_entity_id,
		_target_world_pos,
		SLOT_TAUNT
	)
	player_fsm.set_local_cooldown(SLOT_TAUNT, COOLDOWNS_MS[SLOT_TAUNT])
	_play_swing_anim("taunt")

# ---------------------------------------------------------------------------
# Recepción de resultado del servidor
# ---------------------------------------------------------------------------

## Llamado por network_manager cuando llega SKILL_RESULT.
func on_skill_result(result: Dictionary) -> void:
	match result.get("result_code"):
		0x01:  # HIT
			_show_hit_vfx(result.get("value", 0))
		0x02:  # MISS
			_show_miss_vfx()
		0x04:  # CAST_INTERRUPTED (no aplica al Guerrero, pero se maneja)
			pass

# ---------------------------------------------------------------------------
# Helpers privados
# ---------------------------------------------------------------------------

func _ready_to_act(slot: int) -> bool:
	if player_fsm == null or not player_fsm.can_act():
		return false
	if player_fsm.is_skill_on_cooldown(slot):
		return false
	return true


func _raycast_target(screen_pos: Vector2) -> Dictionary:
	if camera == null:
		return {}

	var ray_from := camera.project_ray_origin(screen_pos)
	var ray_to   := ray_from + camera.project_ray_normal(screen_pos) * MELEE_RANGE_VISUAL_M

	var space_state := camera.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(ray_from, ray_to)
	query.collision_mask = 0b0010  # capa de enemigos/entidades

	var hit := space_state.intersect_ray(query)
	if hit.is_empty():
		return {}

	# El collider debe tener un metadato "entity_id" asignado al instanciar.
	# hit["collider"] es Variant: tipar como Object para poder llamar has_meta.
	var collider: Object = hit["collider"]
	if collider == null or not collider.has_meta("entity_id"):
		return {}

	return {
		"entity_id": int(collider.get_meta("entity_id")),
		"world_pos": hit["position"],
	}


func _play_swing_anim(anim: String) -> void:
	var animator: AnimationPlayer = get_node_or_null("AnimationPlayer")
	if animator and animator.has_animation(anim):
		animator.play(anim)


func _show_hit_vfx(damage: int) -> void:
	# Mostrar número de daño flotante — implementación de UI pendiente
	print("[Warrior] HIT confirmado por servidor: %d daño" % damage)


func _show_miss_vfx() -> void:
	print("[Warrior] MISS — fuera de rango según el servidor")
