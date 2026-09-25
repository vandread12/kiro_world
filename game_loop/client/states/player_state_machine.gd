## player_state_machine.gd
## FSM del jugador local.
## El servidor es la única fuente de verdad: aquí solo manejamos el estado
## visual y de input del cliente. NUNCA calculamos daño ni HP.
##
## Spec: GAMELOOP_TECHNICAL_SPEC.md §2
## Dependencias: world_manager.gd, action_intent_sender.gd

class_name PlayerStateMachine
extends Node

# ---------------------------------------------------------------------------
# Señales
# ---------------------------------------------------------------------------

signal state_changed(old_state: StringName, new_state: StringName)
signal downed_timer_updated(remaining_ms: int)
signal revive_received(new_hp: int)

# ---------------------------------------------------------------------------
# Enum de estados (refleja la FSM del spec §2.2)
# ---------------------------------------------------------------------------

enum State {
	CONNECTING,
	READY,
	ACTIVE,
	DOWNED,
	ELIMINATED,
	MATCH_RESULT,
	DISCONNECTED,
}

# ---------------------------------------------------------------------------
# Estado interno
# ---------------------------------------------------------------------------

var current_state: State = State.CONNECTING
var hp: int = 0
var max_hp: int = 100

# timer_abs: epoch ms recibido desde el servidor. El cliente NUNCA lo calcula.
var _downed_timer_abs_ms: int = 0

# Cooldowns locales: solo para feedback visual. El servidor invalida si no
# concuerdan.
var _cooldowns: Dictionary = {}  # { skill_slot: expire_epoch_ms }

# Referencia al nodo de animación
@onready var _animator: AnimationPlayer = $AnimationPlayer

# ---------------------------------------------------------------------------
# Transiciones de estado
# ---------------------------------------------------------------------------

func transition_to(new_state: State, data: Dictionary = {}) -> void:
	if current_state == new_state:
		return

	var old = current_state
	_exit_state(old)
	current_state = new_state
	_enter_state(new_state, data)
	emit_signal("state_changed", _state_name(old), _state_name(new_state))


func _exit_state(s: State) -> void:
	match s:
		State.DOWNED:
			_downed_timer_abs_ms = 0


func _enter_state(s: State, data: Dictionary) -> void:
	match s:
		State.CONNECTING:
			_play_anim("idle")

		State.READY:
			_play_anim("ready_pose")

		State.ACTIVE:
			hp = data.get("hp", max_hp)
			_play_anim("combat_idle")

		State.DOWNED:
			# timer_abs llega SIEMPRE desde el servidor (paquete PLAYER_DOWNED).
			# Si por alguna razón no viene, el cliente queda en DOWNED sin timer
			# visible hasta que el servidor lo corrija en el siguiente tick.
			_downed_timer_abs_ms = data.get("timer_abs_ms", 0)
			hp = 0
			_play_anim("downed")

		State.ELIMINATED:
			_play_anim("eliminated")

		State.MATCH_RESULT:
			_play_anim("victory" if data.get("won", false) else "defeat")

		State.DISCONNECTED:
			_play_anim("idle")

# ---------------------------------------------------------------------------
# Update loop (llamado por world_manager._process)
# ---------------------------------------------------------------------------

func update(delta: float) -> void:
	if current_state == State.DOWNED:
		_tick_downed_display()


func _tick_downed_display() -> void:
	if _downed_timer_abs_ms == 0:
		return
	var now_ms: int = Time.get_ticks_msec() + _server_clock_offset_ms()
	var remaining: int = _downed_timer_abs_ms - now_ms
	remaining = max(remaining, 0)
	emit_signal("downed_timer_updated", remaining)


## Offset de reloj: el cliente mide el RTT en los HEARTBEAT y estima la
## diferencia con el reloj del servidor. Se actualiza en network_manager.
var _clock_offset_ms: int = 0

func set_server_clock_offset(offset_ms: int) -> void:
	_clock_offset_ms = offset_ms


func _server_clock_offset_ms() -> int:
	return _clock_offset_ms

# ---------------------------------------------------------------------------
# Recepciones de eventos de servidor
# ---------------------------------------------------------------------------

## Llamado por network_manager cuando llega un paquete PLAYER_DOWNED.
func on_server_downed(timer_abs_ms: int) -> void:
	transition_to(State.DOWNED, {"timer_abs_ms": timer_abs_ms})


## Llamado cuando el servidor confirma PLAYER_REVIVED.
func on_server_revived(new_hp: int) -> void:
	transition_to(State.ACTIVE, {"hp": new_hp})
	emit_signal("revive_received", new_hp)


## Llamado cuando el servidor emite PLAYER_ELIMINATED.
func on_server_eliminated() -> void:
	transition_to(State.ELIMINATED)


## Llamado en SYNC_RESP tras reconexión: el servidor envía el estado real.
func on_server_state_sync(state_name: String, data: Dictionary) -> void:
	var s: State = _state_from_string(state_name)
	transition_to(s, data)


## Actualización de HP autoritativa (paquete UPDATE o SKILL_RESULT).
func on_server_hp_update(new_hp: int) -> void:
	hp = new_hp
	if hp <= 0 and current_state == State.ACTIVE:
		# El servidor debería haber enviado PLAYER_DOWNED; si no lo hizo,
		# el cliente espera sin transicionar para no desincronizarse.
		push_warning("[PlayerFSM] HP=0 sin PLAYER_DOWNED del servidor")


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func can_act() -> bool:
	return current_state == State.ACTIVE


func is_skill_on_cooldown(slot: int) -> bool:
	if not _cooldowns.has(slot):
		return false
	var now = Time.get_ticks_msec() + _server_clock_offset_ms()
	return now < _cooldowns[slot]


## El servidor confirma cooldown en SKILL_RESULT. El cliente lo aplica de
## forma optimista en _action_intent_sender para dar feedback visual.
func set_local_cooldown(slot: int, duration_ms: int) -> void:
	var now = Time.get_ticks_msec() + _server_clock_offset_ms()
	_cooldowns[slot] = now + duration_ms


func _play_anim(anim: String) -> void:
	if _animator and _animator.has_animation(anim):
		_animator.play(anim)


func _state_name(s: State) -> StringName:
	return State.keys()[s]


func _state_from_string(name: String) -> State:
	for i in State.keys().size():
		if State.keys()[i] == name:
			return i as State
	push_error("[PlayerFSM] Estado desconocido: " + name)
	return State.DISCONNECTED
