// tick_loop.go
// Bucle de simulación autoritativo a 30 Hz.
// Regla cardinal: CERO escrituras a DynamoDB dentro de este bucle.
// Todo el estado vive en MatchStateAccumulator; se persiste en MATCH_END.
//
// Spec: GAMELOOP_TECHNICAL_SPEC.md §4.1 (Fase 3)

package game

import (
	"context"
	"time"

	"go.uber.org/zap"

	"github.com/pixelrift/gameserver/pkg/spatial"
)

const (
	TickRate         = 30
	TickDuration     = time.Second / TickRate // 33.333 ms
	BossAITickPeriod = 5                      // cada 5 ticks (~166 ms)
	AggroDecayRate   = 0.05                   // por tick
)

// ---------------------------------------------------------------------------
// TickLoop orquesta la simulación del combate
// ---------------------------------------------------------------------------

type TickLoop struct {
	acc         *MatchStateAccumulator
	inputQueue  chan ActionIntent
	broadcaster Broadcaster
	posHistory  *RingPositionHistory
	obstacles   []spatial.Obstacle
	skills      SkillCatalog
	logger      *zap.Logger

	currentTick uint16
}

// NewTickLoop construye un TickLoop listo para ejecutar.
func NewTickLoop(
	acc *MatchStateAccumulator,
	inputQueue chan ActionIntent,
	broadcaster Broadcaster,
	posHistory *RingPositionHistory,
	obstacles []spatial.Obstacle,
	skills SkillCatalog,
	logger *zap.Logger,
) *TickLoop {
	return &TickLoop{
		acc:         acc,
		inputQueue:  inputQueue,
		broadcaster: broadcaster,
		posHistory:  posHistory,
		obstacles:   obstacles,
		skills:      skills,
		logger:      logger,
	}
}

// Broadcaster envía paquetes UDP a todos los clientes.
type Broadcaster interface {
	BroadcastUpdate(state *MatchStateAccumulator, tick uint16)
	SendSkillResult(playerID uint16, result SkillResult)
	BroadcastEvent(event GameEvent, data []byte)
}

// SkillCatalog provee la configuración de habilidades por slot y clase.
type SkillCatalog interface {
	GetSkill(style CombatStyle, slot int) (Skill, bool)
}

// Skill define una habilidad del catálogo.
type Skill struct {
	ID         string
	CastTimeMS int
	CooldownMS int
	BaseDamage int
	BaseHeal   int
	AggroMult  float64
}

// SkillResult es el paquete de respuesta al ActionIntent.
type SkillResult struct {
	Tick        uint16
	CasterID    uint16
	TargetID    uint16
	ResultCode  SkillResultCode
	Value       int
	NewTargetHP int
	AggroDelta  float64
}

// GameEvent es el byte de evento embebido en el paquete UPDATE.
type GameEvent uint8

const (
	EvPlayerDowned     GameEvent = 0x10
	EvPlayerRevived    GameEvent = 0x11
	EvPlayerEliminated GameEvent = 0x12
	EvBossPhase        GameEvent = 0x13
	EvBossDefeated     GameEvent = 0x14
	EvMatchResult      GameEvent = 0x15
)

// ---------------------------------------------------------------------------
// Run — bloquea hasta fin de la partida
// ---------------------------------------------------------------------------

func (tl *TickLoop) Run(ctx context.Context) MatchOutcome {
	ticker := time.NewTicker(TickDuration)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return OutcomeServerAbort

		case <-ticker.C:
			tl.currentTick++
			outcome := tl.runTick()
			if outcome != "" {
				return outcome
			}
		}
	}
}

func (tl *TickLoop) runTick() MatchOutcome {
	// ------------------------------------------------------------------
	// FASE A: INPUT COLLECTION
	// Drenar la cola de intents recibidos durante el tick anterior.
	// ------------------------------------------------------------------
	var intents []ActionIntent
	for {
		select {
		case intent := <-tl.inputQueue:
			intents = append(intents, intent)
		default:
			goto processIntents
		}
	}
processIntents:

	// ------------------------------------------------------------------
	// FASE B: SIMULATION
	// ------------------------------------------------------------------

	// B1. Procesar intents
	for i := range intents {
		tl.processIntent(&intents[i])
	}

	// B1b. Resolver casteos que hayan expirado este tick
	tl.resolveActiveCasts()

	// B2. Boss AI (cada BossAITickPeriod ticks)
	if int(tl.currentTick)%BossAITickPeriod == 0 {
		tl.runBossAI()
	}

	// B3. Aggro decay
	tl.decayAggro()

	// B4. Timers DOWNED
	if outcome := tl.processDowned(); outcome != "" {
		return outcome
	}

	// B5. Condición de victoria
	if tl.acc.Boss != nil && tl.acc.Boss.HP <= 0 {
		tl.broadcaster.BroadcastEvent(EvBossDefeated, nil)
		return OutcomeInvasionRepelled
	}

	// B6. Condición de derrota (todos eliminados)
	if tl.allPlayersEliminated() {
		tl.broadcaster.BroadcastEvent(EvMatchResult, []byte{0x00})
		return OutcomeInvasionFailed
	}

	// ------------------------------------------------------------------
	// FASE C: BROADCAST
	// ------------------------------------------------------------------
	tl.broadcaster.BroadcastUpdate(tl.acc, tl.currentTick)

	// Guardar posición actual para lag compensation del siguiente tick
	for _, p := range tl.acc.Players {
		tl.posHistory.Record(p.PlayerID, tl.currentTick, p.Position)
	}

	return ""
}

// ---------------------------------------------------------------------------
// Procesamiento de ActionIntent
// ---------------------------------------------------------------------------

func (tl *TickLoop) processIntent(intent *ActionIntent) {
	p, ok := tl.acc.Players[intent.PlayerID]
	if !ok || !p.IsActive() {
		return
	}

	switch intent.Action {
	case ActionMeleeStrike:
		tl.resolveMelee(intent, p)
	case ActionCastStart:
		tl.resolveCastStart(intent, p)
	case ActionCastCancel:
		tl.resolveCastCancel(intent)
	case ActionHealApply:
		tl.resolveHeal(intent, p)
	case ActionReviveApply:
		tl.resolveRevive(intent, p)
	case ActionSkillUse:
		tl.resolveSkillUse(intent, p)
	}
}

// ---------------------------------------------------------------------------
// Guerrero — melee (spec §3.2)
// ---------------------------------------------------------------------------

func (tl *TickLoop) resolveMelee(intent *ActionIntent, attacker *Player) {
	target, ok := tl.acc.Players[intent.TargetID]
	if !ok {
		// El objetivo podría ser el Boss
		if tl.acc.Boss != nil && tl.acc.Boss.EntityID == intent.TargetID {
			tl.resolveMeleeVsBoss(intent, attacker)
			return
		}
		tl.sendInvalid(attacker.PlayerID, "unknown_target")
		return
	}

	// Lag compensation: posición del objetivo en el tick que reportó el cliente.
	compensatedPos := tl.posHistory.AtTick(target.PlayerID, intent.ClientTick)
	valid, reason := spatial.ValidateMeleeStrike(
		attacker.Position, compensatedPos, tl.currentTick, intent.ClientTick,
	)
	if !valid {
		tl.broadcaster.SendSkillResult(attacker.PlayerID, SkillResult{
			Tick: tl.currentTick, CasterID: attacker.PlayerID,
			ResultCode: ResultMiss,
		})
		tl.logger.Debug("melee miss", zap.String("reason", reason), zap.Uint16("player", attacker.PlayerID))
		return
	}

	skill, _ := tl.skills.GetSkill(StyleStriking, intent.SkillSlot)
	damage := skill.BaseDamage
	tl.applyDamageToPlayer(attacker, target, damage, skill.AggroMult)
}

func (tl *TickLoop) resolveMeleeVsBoss(intent *ActionIntent, attacker *Player) {
	boss := tl.acc.Boss

	// El Boss no se mueve por lag compensation: su posición actual es autoritativa.
	valid, reason := spatial.ValidateMeleeStrike(
		attacker.Position, boss.Position, tl.currentTick, intent.ClientTick,
	)
	if !valid {
		tl.broadcaster.SendSkillResult(attacker.PlayerID, SkillResult{
			Tick: tl.currentTick, CasterID: attacker.PlayerID, ResultCode: ResultMiss,
		})
		tl.logger.Debug("melee vs boss miss", zap.String("reason", reason))
		return
	}

	skill, _ := tl.skills.GetSkill(StyleStriking, intent.SkillSlot)
	tl.applyDamageToBoss(attacker, skill.BaseDamage, skill.AggroMult)
}

// ---------------------------------------------------------------------------
// Mago — casteo (spec §3.3)
// ---------------------------------------------------------------------------

// activeCasts: casteos en curso por player_id
var activeCasts = map[uint16]*ActiveCast{}

func (tl *TickLoop) resolveCastStart(intent *ActionIntent, caster *Player) {
	if _, exists := activeCasts[caster.PlayerID]; exists {
		tl.sendInvalid(caster.PlayerID, "already_casting")
		return
	}

	valid, reason := spatial.ValidateCastRange(caster.Position, intent.TargetPos)
	if !valid {
		tl.sendInvalid(caster.PlayerID, reason)
		return
	}
	valid, reason = spatial.ValidateCastLOS(caster.Position, intent.TargetPos, tl.obstacles)
	if !valid {
		tl.sendInvalid(caster.PlayerID, reason)
		return
	}

	skill, ok := tl.skills.GetSkill(StyleClinch, intent.SkillSlot)
	if !ok {
		tl.sendInvalid(caster.PlayerID, "unknown_skill")
		return
	}

	activeCasts[caster.PlayerID] = &ActiveCast{
		CasterID:  caster.PlayerID,
		SkillSlot: intent.SkillSlot,
		TargetID:  intent.TargetID,
		TargetPos: intent.TargetPos,
		ExpiresAt: time.Now().Add(time.Duration(skill.CastTimeMS) * time.Millisecond),
	}
}

func (tl *TickLoop) resolveCastCancel(intent *ActionIntent) {
	delete(activeCasts, intent.PlayerID)
}

// resolveActiveCasts se llama una vez por tick para completar casteos expirados.
func (tl *TickLoop) resolveActiveCasts() {
	now := time.Now()
	for pid, cast := range activeCasts {
		if now.Before(cast.ExpiresAt) {
			continue
		}
		delete(activeCasts, pid)

		caster, ok := tl.acc.Players[pid]
		if !ok || !caster.IsActive() {
			continue
		}

		skill, ok := tl.skills.GetSkill(StyleClinch, cast.SkillSlot)
		if !ok {
			continue
		}

		// Revalidar LOS al resolver (el objetivo pudo moverse)
		if valid, _ := spatial.ValidateCastLOS(caster.Position, cast.TargetPos, tl.obstacles); !valid {
			tl.sendInvalid(pid, "no_los_on_resolve")
			continue
		}

		tl.applyDamageToBoss(caster, skill.BaseDamage, skill.AggroMult)
	}
}

// InterruptCast cancela el casteo de un Mago (p.ej., al recibir daño).
func (tl *TickLoop) InterruptCast(playerID uint16) {
	if _, exists := activeCasts[playerID]; !exists {
		return
	}
	delete(activeCasts, playerID)
	tl.broadcaster.SendSkillResult(playerID, SkillResult{
		Tick: tl.currentTick, CasterID: playerID, ResultCode: ResultCastInterrupted,
	})
}

// ---------------------------------------------------------------------------
// Healer — cura y revive (spec §3.4)
// ---------------------------------------------------------------------------

func (tl *TickLoop) resolveHeal(intent *ActionIntent, healer *Player) {
	skill, ok := tl.skills.GetSkill(StyleGrapple, intent.SkillSlot)
	if !ok {
		tl.sendInvalid(healer.PlayerID, "unknown_skill")
		return
	}

	found, target := spatial.FindHealTarget(healer.Position, intent.ForwardVec, tl.healCandidates(healer.PlayerID))
	if !found {
		tl.broadcaster.SendSkillResult(healer.PlayerID, SkillResult{
			Tick: tl.currentTick, CasterID: healer.PlayerID, ResultCode: ResultInvalid,
		})
		return
	}

	tgt := tl.acc.Players[target.PlayerID]

	// Cura efectiva: min(raw, gap) — spec §3.4
	gap := tgt.MaxHP - tgt.HP
	effective := skill.BaseHeal
	if effective > gap {
		effective = gap
	}
	tgt.HP += effective

	// XP por curación efectiva — acumulada sin escribir a DynamoDB
	healer.XPDelta += int(float64(effective) * 0.5) // 0.5 XP/HP curado
	healer.EffHealingDelta += effective
	tl.acc.TotalHealing += effective

	// Aggro del Boss hacia el Healer (spec §3.5)
	if tl.acc.Boss != nil {
		tl.acc.Boss.AggroTable[healer.PlayerID] += float64(effective) * 0.8
	}

	tl.broadcaster.SendSkillResult(healer.PlayerID, SkillResult{
		Tick: tl.currentTick, CasterID: healer.PlayerID, TargetID: tgt.PlayerID,
		ResultCode: ResultHealApplied, Value: effective, NewTargetHP: tgt.HP,
	})
}

func (tl *TickLoop) resolveRevive(intent *ActionIntent, healer *Player) {
	target, ok := tl.acc.Players[intent.TargetID]
	if !ok || target.State != StateDowned {
		tl.sendInvalid(healer.PlayerID, "invalid_target")
		return
	}

	// Validar que el Healer apunta al target (mismo cono que curación)
	found, _ := spatial.FindHealTarget(healer.Position, intent.ForwardVec, tl.healCandidates(healer.PlayerID))
	if !found {
		tl.sendInvalid(healer.PlayerID, "no_target_in_cone")
		return
	}

	// Aplicar REVIVE
	target.State = StateActive
	target.HP = int(float64(target.MaxHP) * 0.30) // 30 % HP al revivir
	target.DownedUntil = time.Time{}

	// Consumir el ítem de revive (se aplica en MATCH_END)
	tl.acc.ItemsConsumed = append(tl.acc.ItemsConsumed, buildItemSK("resurrection_item", "STACK"))

	// Notificar a todos
	buf := serializeReviveEvent(target.PlayerID, uint16(target.HP))
	tl.broadcaster.BroadcastEvent(EvPlayerRevived, buf)

	tl.logger.Info("player revived", zap.Uint16("target", target.PlayerID))
}

func (tl *TickLoop) resolveSkillUse(intent *ActionIntent, p *Player) {
	// Dispatcher genérico según la clase del jugador
	switch p.Style {
	case StyleStriking:
		tl.resolveMelee(intent, p)
	case StyleClinch:
		tl.resolveCastStart(intent, p)
	case StyleGrapple:
		tl.resolveHeal(intent, p)
	}
}

// ---------------------------------------------------------------------------
// Aplicar daño
// ---------------------------------------------------------------------------

func (tl *TickLoop) applyDamageToPlayer(attacker, target *Player, damage int, aggroMult float64) {
	target.HP -= damage
	attacker.DamageDelta += damage
	tl.acc.TotalDamage += damage

	// Interrumpir casteo si el objetivo es un Mago
	if target.Style == StyleClinch {
		tl.InterruptCast(target.PlayerID)
	}

	// Aggro
	if tl.acc.Boss != nil {
		tl.acc.Boss.AggroTable[attacker.PlayerID] += float64(damage) * aggroMult
	}

	if target.HP <= 0 {
		target.HP = 0
		tl.dowPlayer(target)
	}

	tl.broadcaster.SendSkillResult(attacker.PlayerID, SkillResult{
		Tick: tl.currentTick, CasterID: attacker.PlayerID, TargetID: target.PlayerID,
		ResultCode: ResultHit, Value: damage, NewTargetHP: target.HP,
		AggroDelta: float64(damage) * aggroMult,
	})
}

func (tl *TickLoop) applyDamageToBoss(attacker *Player, damage int, aggroMult float64) {
	boss := tl.acc.Boss
	oldPhase := boss.Phase

	boss.HP -= damage
	if boss.HP < 0 {
		boss.HP = 0
	}

	attacker.DamageDelta += damage
	tl.acc.TotalDamage += damage
	boss.AggroTable[attacker.PlayerID] += float64(damage) * aggroMult

	boss.UpdatePhase()
	if boss.Phase != oldPhase {
		tl.broadcaster.BroadcastEvent(EvBossPhase, []byte{byte(boss.Phase)})
		tl.logger.Info("boss phase transition", zap.Uint8("phase", uint8(boss.Phase)))
	}

	tl.broadcaster.SendSkillResult(attacker.PlayerID, SkillResult{
		Tick: tl.currentTick, CasterID: attacker.PlayerID, TargetID: boss.EntityID,
		ResultCode: ResultHit, Value: damage, NewTargetHP: boss.HP,
		AggroDelta: float64(damage) * aggroMult,
	})
}

// ---------------------------------------------------------------------------
// DOWNED
// ---------------------------------------------------------------------------

func (tl *TickLoop) dowPlayer(p *Player) {
	p.State = StateDowned
	p.DownedUntil = time.Now().Add(180 * time.Second) // timer_abs del spec §2.3

	buf := serializeDownedEvent(p.PlayerID, p.DownedUntil.UnixMilli())
	tl.broadcaster.BroadcastEvent(EvPlayerDowned, buf)

	tl.logger.Info("player downed",
		zap.Uint16("player", p.PlayerID),
		zap.Time("until", p.DownedUntil),
	)
}

// processDowned itera jugadores en DOWNED y los elimina si expiró el timer.
func (tl *TickLoop) processDowned() MatchOutcome {
	now := time.Now()
	for _, p := range tl.acc.Players {
		if p.State != StateDowned {
			continue
		}
		if now.After(p.DownedUntil) {
			p.State = StateEliminated
			tl.broadcaster.BroadcastEvent(EvPlayerEliminated, serializeUint16(p.PlayerID))
			tl.logger.Info("player eliminated (downed expired)", zap.Uint16("player", p.PlayerID))
		}
	}
	return ""
}

// ---------------------------------------------------------------------------
// Boss AI (spec §4.1 Fase 3 → §4.2)
// ---------------------------------------------------------------------------

func (tl *TickLoop) runBossAI() {
	boss := tl.acc.Boss
	if boss == nil || boss.HP <= 0 {
		return
	}

	// Seleccionar target con mayor aggro
	boss.SelectTarget(tl.acc.Players)
	if boss.Target == 0 {
		return
	}

	target, ok := tl.acc.Players[boss.Target]
	if !ok {
		return
	}

	// Daño base según fase
	baseDamage := bossBaseDamageForPhase(boss.Phase)
	target.HP -= baseDamage
	if target.HP <= 0 {
		target.HP = 0
		tl.dowPlayer(target)
	}
}

func bossBaseDamageForPhase(phase BossPhase) int {
	switch phase {
	case Phase1:
		return 12
	case Phase2:
		return 18
	case Phase3:
		return 25
	default:
		return 12
	}
}

// ---------------------------------------------------------------------------
// Aggro decay (spec §3.5)
// ---------------------------------------------------------------------------

func (tl *TickLoop) decayAggro() {
	if tl.acc.Boss == nil {
		return
	}
	for pid := range tl.acc.Boss.AggroTable {
		tl.acc.Boss.AggroTable[pid] *= (1.0 - AggroDecayRate)
		if tl.acc.Boss.AggroTable[pid] < 0.01 {
			tl.acc.Boss.AggroTable[pid] = 0
		}
	}
}

// ---------------------------------------------------------------------------
// Helpers de verificación
// ---------------------------------------------------------------------------

func (tl *TickLoop) allPlayersEliminated() bool {
	for _, p := range tl.acc.Players {
		if p.State == StateActive || p.State == StateDowned {
			return false
		}
	}
	return true
}

// healCandidates traduce los jugadores del acumulador al tipo agnóstico que
// espera el paquete spatial, excluyendo al propio Healer. Esta traducción es la
// que mantiene a spatial libre de dependencias del dominio de game.
func (tl *TickLoop) healCandidates(healerID uint16) []spatial.Healable {
	out := make([]spatial.Healable, 0, len(tl.acc.Players))
	for pid, p := range tl.acc.Players {
		if pid == healerID {
			continue
		}
		out = append(out, spatial.Healable{
			PlayerID: pid,
			Position: p.Position,
			Kind:     toTargetKind(p.State),
		})
	}
	return out
}

// toTargetKind mapea el PlayerState de game al TargetKind neutro de spatial.
func toTargetKind(s PlayerState) spatial.TargetKind {
	switch s {
	case StateActive:
		return spatial.TargetActive
	case StateDowned:
		return spatial.TargetDowned
	default:
		return spatial.TargetOther
	}
}

func (tl *TickLoop) sendInvalid(playerID uint16, reason string) {
	tl.broadcaster.SendSkillResult(playerID, SkillResult{
		Tick: tl.currentTick, CasterID: playerID, ResultCode: ResultInvalid,
	})
	tl.logger.Debug("invalid action", zap.Uint16("player", playerID), zap.String("reason", reason))
}

// ---------------------------------------------------------------------------
// Serialización de eventos (formato binario mínimo)
// ---------------------------------------------------------------------------

func serializeDownedEvent(playerID uint16, timerAbsMS int64) []byte {
	b := make([]byte, 10) // 1 byte event + 2 playerID + 8 timer_abs
	b[0] = byte(EvPlayerDowned)
	b[1] = byte(playerID >> 8)
	b[2] = byte(playerID)
	for i := 0; i < 8; i++ {
		b[3+i] = byte(timerAbsMS >> (56 - 8*i))
	}
	return b
}

func serializeReviveEvent(playerID uint16, newHP uint16) []byte {
	return []byte{
		byte(EvPlayerRevived),
		byte(playerID >> 8), byte(playerID),
		byte(newHP >> 8), byte(newHP),
	}
}

func serializeUint16(v uint16) []byte {
	return []byte{byte(v >> 8), byte(v)}
}

func buildItemSK(itemDef, instanceID string) string {
	return "ITEM#" + itemDef + "#" + instanceID
}

// ---------------------------------------------------------------------------
// RingPositionHistory — lag compensation (spec §3.2)
// ---------------------------------------------------------------------------

const historyDepth = 8 // cubre 8 ticks (>MeleeMaxLagTicks=2 con margen)

// RingPositionHistory almacena las últimas `historyDepth` posiciones de cada jugador.
type RingPositionHistory struct {
	data map[uint16][historyDepth]posEntry
}

type posEntry struct {
	tick uint8
	pos  Vec3CM
}

func NewRingPositionHistory() *RingPositionHistory {
	return &RingPositionHistory{data: make(map[uint16][historyDepth]posEntry)}
}

// Record guarda la posición del jugador en este tick.
func (h *RingPositionHistory) Record(playerID uint16, tick uint16, pos Vec3CM) {
	ring := h.data[playerID]
	idx := tick % historyDepth
	ring[idx] = posEntry{tick: uint8(tick), pos: pos}
	h.data[playerID] = ring
}

// AtTick devuelve la posición más cercana al tick pedido.
// Si no hay dato exacto, usa la más antigua disponible.
func (h *RingPositionHistory) AtTick(playerID uint16, tick uint8) Vec3CM {
	ring, ok := h.data[playerID]
	if !ok {
		return Vec3CM{}
	}
	// Búsqueda exacta primero
	for _, e := range ring {
		if e.tick == tick {
			return e.pos
		}
	}
	// Fallback: entrada más reciente
	var best posEntry
	for _, e := range ring {
		if e.tick != 0 {
			best = e
		}
	}
	return best.pos
}
