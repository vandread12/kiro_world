## healer_controller.gd
## Controlador del Healer (combatStyle = GRAPPLE).
## Mecánica central: apuntar la cámara hacia un aliado para curar/revivir.
## El servidor hace el raycasting real; el cliente solo reporta el forward_vector.
##
## Spec: GAMELOOP_TECHNICAL_SPEC.md §3.4

class_name HealerController
extends Node

# ---------------------------------------------------------------------------
# Señales
# ---------------------------------------------------------------------------

signal heal_applied(target_id: int, amount: int)
signal revive_applied(target_id: int)
signal aim_target_changed(target_id: int, in_cone: bool)

# ---------------------------------------------------------------------------
# Dependencias
# ---------------------------------------------------------------------------

@export var intent_sender: ActionIntentSender
@export var player_fsm: PlayerStateMachine
@export var camera: Camera3D
@export var cloud_anchor_node: Node3D

# ---------------------------------------------------------------------------
# Configuración
# ---------------------------------------------------------------------------

const SLOT_HEAL_BASIC:   int = 0
const SLOT_HEAL_BURST:   int = 1
const SLOT_REVIVE_ITEM:  int = 2

const COOLDOWNS_MS: Dictionary = {
	SLOT_HEAL_BASIC:  2000,
	SLOT_HEAL_BURST:  6000,
	SLOT_REVIVE_ITEM: 0,   # el cooldown lo marca el consumo del ítem
}

## Umbral de cono visual de apuntado (cos 35°).
## El servidor usa cos(30°) = 0.866; 35° da un margen visual mayor para el
## feedback del reticle sin prometer un heal que el servidor rechazará.
const AIM_DOT_VISUAL: float = 0.819

## Rango máximo visual de cura (m). Servidor: 10 m.
const HEAL_RANGE_VISUAL_M: float = 11.0

# ---------------------------------------------------------------------------
# Estado local del reticle de apuntado
# ---------------------------------------------------------------------------

var _current_aim_target_id: int = -1
var _aim_in_cone: bool = false

# ---------------------------------------------------------------------------
# Update loop — detecta aliado en la mira y actualiza el reticle
# ---------------------------------------------------------------------------

func update(_delta: float) -> void:
	if not player_fsm or not player_fsm.can_act():
		return
	_update_aim()


func _update_aim() -> void:
	var fwd := -camera.global_transform.basis.z.normalized()
	var best_id: int = -1
	var best_dot: float = AIM_DOT_VISUAL

	# Iterar sobre aliados visibles (RemotePlayersGroup hijos del CloudAnchorNode)
	if cloud_anchor_node == null:
		return

	var group := cloud_anchor_node.get_node_or_null("RemotePlayersGroup")
	if group == null:
		return

	for child in group.get_children():
		var ally := child as Node3D
		if ally == null or not ally.has_meta("player_id"):
			continue
		var pid: int = int(ally.get_meta("player_id"))
		var to_ally: Vector3 = ally.global_position - camera.global_position
		var dist_m: float = to_ally.length()
		if dist_m > HEAL_RANGE_VISUAL_M or dist_m < 0.1:
			continue

		var dot: float = fwd.dot(to_ally.normalized())
		if dot > best_dot:
			best_dot   = dot
			best_id    = pid

	var in_cone := best_id >= 0
	if best_id != _current_aim_target_id or in_cone != _aim_in_cone:
		_current_aim_target_id = best_id
		_aim_in_cone           = in_cone
		emit_signal("aim_target_changed", best_id, in_cone)

# ---------------------------------------------------------------------------
# Input — botón de curar / revivir
# ---------------------------------------------------------------------------

func on_heal_press(slot: int) -> void:
	if not _ready_to_act(slot):
		return
	if not _aim_in_cone:
		return  # feedback visual: reticle apaga confirmación

	var fwd := -camera.global_transform.basis.z.normalized()
	intent_sender.send_heal_apply(slot, fwd)
	player_fsm.set_local_cooldown(slot, COOLDOWNS_MS.get(slot, 0))


func on_revive_press(target_id: int) -> void:
	if not _ready_to_act(SLOT_REVIVE_ITEM):
		return
	var fwd := -camera.global_transform.basis.z.normalized()
	intent_sender.send_revive_apply(target_id, fwd, SLOT_REVIVE_ITEM)

# ---------------------------------------------------------------------------
# Resultado del servidor
# ---------------------------------------------------------------------------

func on_skill_result(result: Dictionary) -> void:
	match result.get("result_code"):
		0x07:  # HEAL_APPLIED
			var tid: int = result.get("target_id", -1)
			var amt: int = result.get("value", 0)
			emit_signal("heal_applied", tid, amt)
			_show_heal_vfx(tid, amt)
		0x08:  # REVIVE_APPLIED
			var tid: int = result.get("target_id", -1)
			emit_signal("revive_applied", tid)
		0x06:  # INVALID
			_show_miss_vfx()

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _ready_to_act(slot: int) -> bool:
	return player_fsm != null \
		and player_fsm.can_act() \
		and not player_fsm.is_skill_on_cooldown(slot)


func _show_heal_vfx(target_id: int, amount: int) -> void:
	print("[Healer] Curación confirmada: target=%d amount=%d" % [target_id, amount])


func _show_miss_vfx() -> void:
	print("[Healer] Sin objetivo en cono — servidor rechazó la acción")
