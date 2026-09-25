// validator.go
// Validadores espaciales server-side por clase.
// Toda lógica de hitbox, LOS y raycasting de cono vive aquí.
//
// Este paquete es DELIBERADAMENTE de bajo nivel: no importa `game` ni ningún
// otro paquete de dominio. Solo conoce geometría (Vec3CM) y datos mínimos.
// Así se evita el ciclo de importación game <-> spatial: `game` depende de
// `spatial`, nunca al revés.
//
// Spec: GAMELOOP_TECHNICAL_SPEC.md §3

package spatial

import "math"

// ---------------------------------------------------------------------------
// Geometría — Vec3CM
// Posición 3D en centímetros (relativa al CloudAnchor).
// Vive aquí, en el paquete de más bajo nivel, para que tanto `game` como los
// validadores la compartan sin crear un ciclo.
// ---------------------------------------------------------------------------

type Vec3CM struct {
	X, Y, Z int32
}

// DistanceM devuelve la distancia euclidiana en metros.
func (a Vec3CM) DistanceM(b Vec3CM) float64 {
	dx := float64(a.X - b.X)
	dy := float64(a.Y - b.Y)
	dz := float64(a.Z - b.Z)
	return math.Sqrt(dx*dx+dy*dy+dz*dz) / 100.0
}

// Normalized devuelve un vector unitario (float64[3]).
func (v Vec3CM) Normalized() [3]float64 {
	length := math.Sqrt(float64(v.X*v.X) + float64(v.Y*v.Y) + float64(v.Z*v.Z))
	if length == 0 {
		return [3]float64{}
	}
	return [3]float64{float64(v.X) / length, float64(v.Y) / length, float64(v.Z) / length}
}

// Sub resta dos vectores.
func (a Vec3CM) Sub(b Vec3CM) Vec3CM {
	return Vec3CM{a.X - b.X, a.Y - b.Y, a.Z - b.Z}
}

// ---------------------------------------------------------------------------
// TargetKind: estado del objetivo, agnóstico del enum de `game`.
// El paquete `game` traduce su PlayerState a estos valores al llamar.
// ---------------------------------------------------------------------------

type TargetKind uint8

const (
	TargetActive TargetKind = iota
	TargetDowned
	TargetOther // cualquier estado que no sea curable/objetivo
)

// Healable indica los aliados válidos para el cono del Healer.
type Healable struct {
	PlayerID uint16
	Position Vec3CM
	Kind     TargetKind
}

// ---------------------------------------------------------------------------
// Guerrero — validación melee (spec §3.2)
// ---------------------------------------------------------------------------

const (
	MeleeBaseRangeM    = 2.0
	MeleeLagCompRangeM = 0.3 // tolerancia para lag compensation
	MeleeMaxLagTicks   = 2
)

// ValidateMeleeStrike comprueba si el intento de golpe del Guerrero es válido.
// Recibe solo geometría: posición del atacante y posición COMPENSADA del objetivo
// (el llamador ya aplicó lag compensation con el historial de posiciones).
func ValidateMeleeStrike(
	attackerPos Vec3CM,
	compensatedTargetPos Vec3CM,
	serverTick uint16,
	clientTick uint8,
) (valid bool, reason string) {
	lagTicks := int(serverTick) - int(clientTick)
	// uint8 wrap: si el cliente estaba en tick 254 y el servidor en 2
	if lagTicks < 0 {
		lagTicks += 256
	}
	if lagTicks > MeleeMaxLagTicks {
		return false, "stale_input"
	}

	dist := attackerPos.DistanceM(compensatedTargetPos)
	if dist > MeleeBaseRangeM+MeleeLagCompRangeM {
		return false, "out_of_range"
	}
	return true, ""
}

// ---------------------------------------------------------------------------
// Mago — validación de línea de visión (spec §3.3)
// ---------------------------------------------------------------------------

// AABB axis-aligned bounding box de un obstáculo del entorno.
type AABB struct {
	Min, Max Vec3CM
}

// Obstacle es un obstáculo estático cargado en el SYNC_RESP inicial.
type Obstacle struct {
	Box AABB
}

// ValidateCastLOS comprueba que no haya obstáculo entre el Mago y el objetivo.
func ValidateCastLOS(
	casterPos Vec3CM,
	targetPos Vec3CM,
	obstacles []Obstacle,
) (valid bool, reason string) {
	for i := range obstacles {
		if rayIntersectsAABB(casterPos, targetPos, obstacles[i].Box) {
			return false, "no_los"
		}
	}
	return true, ""
}

// ValidateCastRange comprueba que el Mago esté en el rango [2, 15] m del objetivo.
func ValidateCastRange(casterPos Vec3CM, targetPos Vec3CM) (valid bool, reason string) {
	dist := casterPos.DistanceM(targetPos)
	if dist < 2.0 {
		return false, "too_close"
	}
	if dist > 15.0 {
		return false, "out_of_range"
	}
	return true, ""
}

// ---------------------------------------------------------------------------
// Healer — validación de cono de raycasting (spec §3.4)
// ---------------------------------------------------------------------------

const (
	HealConeHalfAngleCos = 0.866 // cos(30°)
	HealMaxRangeM        = 10.0
)

// HealTarget describe el aliado más cercano al rayo del Healer.
type HealTarget struct {
	PlayerID uint16
	Distance float64
}

// FindHealTarget busca el aliado más centrado en el cono de apuntado.
// forward es el vector normalizado de la cámara del Healer (decodificado de q15).
// candidates: aliados curables (el llamador excluye al propio Healer).
func FindHealTarget(
	healerPos Vec3CM,
	forward [3]float64,
	candidates []Healable,
) (found bool, target HealTarget) {
	bestDot := HealConeHalfAngleCos // mínimo para estar dentro del cono

	for _, c := range candidates {
		if c.Kind != TargetActive && c.Kind != TargetDowned {
			continue
		}
		diff := c.Position.Sub(healerPos)
		dist := healerPos.DistanceM(c.Position)
		if dist > HealMaxRangeM || dist < 0.01 {
			continue
		}
		normDiff := diff.Normalized()
		dot := normDiff[0]*forward[0] + normDiff[1]*forward[1] + normDiff[2]*forward[2]

		if dot > bestDot {
			bestDot = dot
			target = HealTarget{PlayerID: c.PlayerID, Distance: dist}
			found = true
		}
	}
	return
}

// ---------------------------------------------------------------------------
// Raycast AABB interno (slab method)
// ---------------------------------------------------------------------------

// rayIntersectsAABB devuelve true si el segmento [from, to] intersecta la AABB.
func rayIntersectsAABB(from, to Vec3CM, box AABB) bool {
	ox, oy, oz := float64(from.X), float64(from.Y), float64(from.Z)
	dx := float64(to.X - from.X)
	dy := float64(to.Y - from.Y)
	dz := float64(to.Z - from.Z)

	tmin := 0.0
	tmax := 1.0

	axes := [][3]float64{
		{dx, float64(box.Min.X), float64(box.Max.X)},
		{dy, float64(box.Min.Y), float64(box.Max.Y)},
		{dz, float64(box.Min.Z), float64(box.Max.Z)},
	}
	origins := []float64{ox, oy, oz}

	for i, axis := range axes {
		d := axis[0]
		bmin := axis[1]
		bmax := axis[2]
		o := origins[i]

		if math.Abs(d) < 1e-8 {
			// Rayo paralelo al plano
			if o < bmin || o > bmax {
				return false
			}
			continue
		}
		t1 := (bmin - o) / d
		t2 := (bmax - o) / d
		if t1 > t2 {
			t1, t2 = t2, t1
		}
		tmin = math.Max(tmin, t1)
		tmax = math.Min(tmax, t2)
		if tmin > tmax {
			return false
		}
	}
	return true
}
