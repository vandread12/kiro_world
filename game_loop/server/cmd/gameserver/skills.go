// skills.go
// Catálogo estático de habilidades por clase y slot.
// Implementa la interfaz game.SkillCatalog.
//
// En producción estos valores vendrían de un fichero de configuración de diseño
// (balance del juego), no hardcodeados. Aquí se definen los valores de referencia
// del spec §3 y §6.

package main

import "github.com/pixelrift/gameserver/pkg/game"

// StaticSkillCatalog es una implementación en memoria del catálogo de skills.
type StaticSkillCatalog struct {
	skills map[skillKey]game.Skill
}

type skillKey struct {
	style game.CombatStyle
	slot  int
}

// NewStaticSkillCatalog construye el catálogo con los valores de referencia.
func NewStaticSkillCatalog() *StaticSkillCatalog {
	c := &StaticSkillCatalog{skills: make(map[skillKey]game.Skill)}

	// --- Guerrero (STRIKING) — aggro alto (spec §3.5: melee = damage × 1.5) ---
	c.set(game.StyleStriking, 0, game.Skill{
		ID: "warrior_strike_basic", CooldownMS: 800, BaseDamage: 45, AggroMult: 1.5,
	})
	c.set(game.StyleStriking, 1, game.Skill{
		ID: "warrior_strike_heavy", CooldownMS: 2000, BaseDamage: 90, AggroMult: 1.5,
	})
	c.set(game.StyleStriking, 2, game.Skill{
		ID: "warrior_taunt", CooldownMS: 8000, BaseDamage: 0, AggroMult: 0, // +500 flat lo aplica el tick loop
	})

	// --- Mago (CLINCH) — cast time, aggro medio (spec §3.5: hechizo = damage × 1.0) ---
	c.set(game.StyleClinch, 0, game.Skill{
		ID: "mage_fireball_01", CastTimeMS: 1500, CooldownMS: 3000, BaseDamage: 120, AggroMult: 1.0,
	})
	c.set(game.StyleClinch, 1, game.Skill{
		ID: "mage_frostbolt_01", CastTimeMS: 2000, CooldownMS: 4000, BaseDamage: 150, AggroMult: 1.0,
	})
	c.set(game.StyleClinch, 2, game.Skill{
		ID: "mage_nova_01", CastTimeMS: 3000, CooldownMS: 12000, BaseDamage: 200, AggroMult: 1.0,
	})

	// --- Healer (GRAPPLE) — cura, aggro bajo (spec §3.5: cura = heal × 0.8) ---
	c.set(game.StyleGrapple, 0, game.Skill{
		ID: "healer_heal_basic", CooldownMS: 2000, BaseHeal: 60, AggroMult: 0.8,
	})
	c.set(game.StyleGrapple, 1, game.Skill{
		ID: "healer_heal_burst", CooldownMS: 6000, BaseHeal: 140, AggroMult: 0.8,
	})
	c.set(game.StyleGrapple, 2, game.Skill{
		ID: "healer_revive_item", CooldownMS: 0, BaseHeal: 0, AggroMult: 0,
	})

	return c
}

func (c *StaticSkillCatalog) set(style game.CombatStyle, slot int, s game.Skill) {
	c.skills[skillKey{style, slot}] = s
}

// GetSkill implementa game.SkillCatalog.
func (c *StaticSkillCatalog) GetSkill(style game.CombatStyle, slot int) (game.Skill, bool) {
	s, ok := c.skills[skillKey{style, slot}]
	return s, ok
}

// Verificación en compilación de que satisface la interfaz.
var _ game.SkillCatalog = (*StaticSkillCatalog)(nil)
