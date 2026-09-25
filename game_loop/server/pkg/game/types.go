// types.go
// Tipos de dominio del Game Loop.
// Estos structs son la fuente de verdad en memoria durante el combate.
// DynamoDB solo se toca en MATCH_JOIN y MATCH_END.
//
// Spec: GAMELOOP_TECHNICAL_SPEC.md §2.2, §3, §6

package game

import (
	"time"

	"github.com/pixelrift/gameserver/pkg/spatial"
)

// ---------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------

// PlayerState refleja la FSM del spec §2.1.
type PlayerState uint8

const (
	StateConnecting PlayerState = iota
	StateReady
	StateActive
	StateDowned
	StateEliminated
	StateMatchResult
	StateDisconnected
)

// CombatStyle coincide con el enum combatStyle de _common.json.
type CombatStyle uint8

const (
	StyleStriking CombatStyle = iota // Guerrero / melee
	StyleClinch                      // Mago / rango
	StyleGrapple                     // Healer / soporte
)

// BossPhase controla la IA del Boss (spec §4.2).
type BossPhase uint8

const (
	Phase1 BossPhase = iota // 100-60 % HP
	Phase2                  // 59-30 %
	Phase3                  // 29-0 %
)

// ActionType refleja el byte 5 del ActionIntent (spec §5.1).
type ActionType uint8

const (
	ActionMeleeStrike ActionType = 0x01
	ActionCastStart   ActionType = 0x02
	ActionCastCancel  ActionType = 0x03
	ActionHealApply   ActionType = 0x04
	ActionReviveApply ActionType = 0x05
	ActionSkillUse    ActionType = 0x06
)

// SkillResultCode: byte de resultado en paquete SKILL_RESULT (0x06).
type SkillResultCode uint8

const (
	ResultHit             SkillResultCode = 0x01
	ResultMiss            SkillResultCode = 0x02
	ResultBlocked         SkillResultCode = 0x03
	ResultCastInterrupted SkillResultCode = 0x04
	ResultHealApplied     SkillResultCode = 0x07
	ResultReviveApplied   SkillResultCode = 0x08
	ResultInvalid         SkillResultCode = 0x06
)

// MatchOutcome coincide con el enum matchOutcome de _common.json.
type MatchOutcome string

const (
	OutcomeInvasionRepelled MatchOutcome = "INVASION_REPELLED"
	OutcomeInvasionFailed   MatchOutcome = "INVASION_FAILED"
	OutcomeAbandoned        MatchOutcome = "ABANDONED"
	OutcomeServerAbort      MatchOutcome = "SERVER_ABORT"
)

// ---------------------------------------------------------------------------
// Posición 3D en centímetros (relativa al CloudAnchor)
// ---------------------------------------------------------------------------

// Vec3CM es un alias del tipo geométrico definido en `spatial`.
// Vive en el paquete de más bajo nivel para que game y los validadores lo
// compartan sin ciclo de importación. Coincide con el campo PositionX/Y/Z del
// protocolo UDP (int32, cm).
type Vec3CM = spatial.Vec3CM

// ---------------------------------------------------------------------------
// Jugador en memoria
// ---------------------------------------------------------------------------

type Player struct {
	PlayerID    uint16
	SessionID   string
	RemoteAddr  string // "ip:puerto" del cliente UDP
	State       PlayerState
	Style       CombatStyle
	HP          int
	MaxHP       int
	AggroScore  float64
	Position    Vec3CM
	DownedUntil time.Time // time.IsZero() si no está downed; timer_abs del spec §2.3

	// Cooldowns: slot → tiempo de expiración
	Cooldowns map[int]time.Time

	// Acumulador de partida (se sella en MATCH_END, no se escribe antes)
	XPDelta          int
	DamageDelta      int
	EffHealingDelta  int // cura efectiva (min(raw, gap)) — discriminada en MATCH_END
	KillContribution int // para cálculo de loot

	// Referencia a los ítems de recompensa calculados en loot distribution
	PendingRewards []LootItem
}

// IsActive devuelve true si el jugador puede actuar.
func (p *Player) IsActive() bool {
	return p.State == StateActive
}

// IsDowned devuelve true durante el cooldown de 3 minutos.
func (p *Player) IsDowned() bool {
	return p.State == StateDowned
}

// ---------------------------------------------------------------------------
// Ítem de botín
// ---------------------------------------------------------------------------

type LootItem struct {
	ItemDef    string // item_def id del catálogo
	InstanceID string // hash(match_id + player_id + idx), 8 hex chars
	Quantity   int
}

// ---------------------------------------------------------------------------
// Cast en progreso (Mago)
// ---------------------------------------------------------------------------

type ActiveCast struct {
	CasterID  uint16
	SkillSlot int
	TargetID  uint16
	TargetPos Vec3CM
	ExpiresAt time.Time
}

// ---------------------------------------------------------------------------
// Boss
// ---------------------------------------------------------------------------

type Boss struct {
	EntityID   uint16
	HP         int
	MaxHP      int
	Position   Vec3CM
	Phase      BossPhase
	Target     uint16 // player_id con mayor aggro
	AggroTable map[uint16]float64
}

func (b *Boss) UpdatePhase() {
	pct := float64(b.HP) / float64(b.MaxHP) * 100.0
	switch {
	case pct > 60:
		b.Phase = Phase1
	case pct > 30:
		b.Phase = Phase2
	default:
		b.Phase = Phase3
	}
}

// SelectTarget elige el jugador con mayor aggro entre los que están ACTIVE.
func (b *Boss) SelectTarget(players map[uint16]*Player) {
	var best uint16
	var bestScore float64
	for pid, score := range b.AggroTable {
		p, ok := players[pid]
		if !ok || !p.IsActive() {
			continue
		}
		if score > bestScore {
			bestScore = score
			best = pid
		}
	}
	b.Target = best
}

// ---------------------------------------------------------------------------
// ActionIntent recibido del cliente
// ---------------------------------------------------------------------------

type ActionIntent struct {
	PacketID   uint16
	PlayerID   uint16
	ClientTick uint8
	Action     ActionType
	TargetID   uint16
	TargetPos  Vec3CM
	SkillSlot  int
	ForwardVec [3]float64 // vector forward normalizado de la cámara (q15 decodificado)
}

// ---------------------------------------------------------------------------
// MatchStateAccumulator — datos en memoria sellados en MATCH_END
// ---------------------------------------------------------------------------

type MatchStateAccumulator struct {
	MatchID       string
	SquadID       string
	Season        int
	Sealed        bool
	Players       map[uint16]*Player
	TotalDamage   int
	TotalHealing  int
	Boss          *Boss
	Outcome       MatchOutcome
	StartedAt     time.Time
	EndedAt       time.Time
	ItemsConsumed []string // Sort Keys de ítems consumidos durante el combate
}

// Seal congela el acumulador. Cualquier mutación posterior es un bug.
func (a *MatchStateAccumulator) Seal(outcome MatchOutcome) {
	a.Sealed = true
	a.Outcome = outcome
	a.EndedAt = time.Now().UTC()
}
