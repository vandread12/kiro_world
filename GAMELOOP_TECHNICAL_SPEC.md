# TECHNICAL SPEC — Core Game Loop de PixelRift
## Mecánicas de Combate · FSM de Jugador · Economía Dual · Validación AR

**Versión:** 1.0 | **Estado:** Pendiente de aprobación  
**Dependencias:** `MULTIPLAYER_TECHNICAL_SPEC.md` (tick rate, payload UDP, CloudAnchor)  
**Dependencias:** `PERSISTENCE_TECHNICAL_SPEC.md` (DynamoDB, monedas, MATCH_END)

---

## 1. Principios de Autoridad del Servidor

El cliente (app AR) es **deliberadamente tonto**. Solo puede enviar _intentos de acción_. Nunca recibe un resultado sin que el servidor lo haya calculado primero.

| Capa | Responsabilidad | Prohibido |
|------|-----------------|-----------|
| **Cliente** | Capturar input táctil / cámara, enviar `ActionIntent` por UDP, interpolar visualmente | Calcular daño, mover entidades autoritativas, leer HP del oponente |
| **Servidor** | Validar distancia, línea de visión, cooldowns, HP, aggro, economía | Aceptar valores de HP/posición provenientes del cliente |

Esto conecta directamente con el modelo de datos: el campo `active_session` en `PlayerProfile` garantiza que un jugador solo tenga un escritor lógico activo a la vez (ver `PERSISTENCE_TECHNICAL_SPEC.md §4.3`).

---

## 2. FSM del Jugador — Máquina de Estados Finitos

### 2.1 Diagrama de Transición de Estados

```
                    ┌─────────────────────────────────────────────────────────────────┐
                    │                     FSM: PLAYER LIFECYCLE                        │
                    └─────────────────────────────────────────────────────────────────┘

                              MATCH_JOIN
                                  │
                                  ▼
                         ┌─────────────────┐
                         │   CONNECTING    │ ← resolve CloudAnchor (timeout 5s)
                         └───────┬─────────┘
                                 │ anchor resuelto
                                 ▼
                         ┌─────────────────┐  timeout/kick
                         │     READY       │──────────────────────────────► DISCONNECTED
                         └───────┬─────────┘
                                 │ match_start
                                 ▼
             ┌──────────────────────────────────────────┐
             │                 ACTIVE                   │◄─────────────────────┐
             │  HP > 0 · puede atacar/curar/moverse     │                      │
             └────┬────────────────┬────────────────────┘                      │
                  │ hp == 0        │ match_end / boss_killed                    │
                  │                ▼                                            │
                  │       ┌──────────────────┐                                 │
                  │       │   MATCH_RESULT   │ ── settlement ──► DynamoDB      │
                  │       └──────────────────┘                                 │
                  ▼                                                             │
         ┌─────────────────┐                                                   │
         │     DOWNED      │  HP = 0 · timer_abs = server_now + 180s          │
         │  (3 min timer)  │  puede recibir REVIVE de Healer                  │
         └────┬────────────┘                                                   │
              │                  ┌──────────────────┐                          │
              │ timer expires    │   REVIVE attempt │                          │
              │ sin revivir      │   (desde Healer) │                          │
              ▼                  └──────┬───────────┘                          │
         ┌──────────────┐               │ servidor valida                      │
         │  ELIMINATED  │               │ raycast + item                       │
         │  (this match)│       ┌───────┴──────────┐                           │
         └──────────────┘       │ válido  │ inválido│                           │
                                │         │         │                           │
                                ▼         ▼         │                           │
                           ACTIVE ────────┘         │                           │
                          (HP = 30)                  └── DOWNED continúa ───────┘
                               │
                               └──────────────────────────────────────────────►(ya arriba)
```

### 2.2 Estados y Datos

| Estado | Condición de entrada | Datos en memoria del servidor | Datos en DynamoDB |
|--------|----------------------|-------------------------------|-------------------|
| `CONNECTING` | MATCH_JOIN recibido | `session_token`, `cloud_anchor_id` | `active_session` escrito |
| `READY` | Cloud Anchor resuelto | `spawn_position` (relativa al anchor) | — |
| `ACTIVE` | match_start o REVIVE | `hp`, `max_hp`, `cooldowns{}`, `aggro_score` | — |
| `DOWNED` | `hp == 0` | `timer_abs` (epoch ms), `hp = 0` | — |
| `ELIMINATED` | `server_now >= timer_abs` sin REVIVE | — | — |
| `MATCH_RESULT` | boss muerto o `INVASION_FAILED` | `MatchStateAccumulator` sellado | `MATCH_END` → DynamoDB |
| `DISCONNECTED` | timeout keepalive (> 30s sin HEARTBEAT) | — | `active_session` NO se borra hasta reconexión |

### 2.3 El Estado DOWNED — Detalles de Implementación

**Regla cardinal: el timer vive en el servidor.**

```
──────────────────────────────────────────────────────────────────────────
  SERVIDOR (Go/C++)
──────────────────────────────────────────────────────────────────────────
  on hp_reaches_zero(player_id):
      player.state      = DOWNED
      player.timer_abs  = time.now_unix_ms() + 180_000   // 180 segundos
      player.hp         = 0
      broadcast(PLAYER_DOWNED, player_id, timer_abs)     // notifica clientes
      // NO escribe en DynamoDB todavía

  on tick():   // cada 33.3 ms
      for p in downed_players:
          remaining = p.timer_abs - time.now_unix_ms()
          if remaining <= 0:
              p.state = ELIMINATED
              broadcast(PLAYER_ELIMINATED, p.player_id)
──────────────────────────────────────────────────────────────────────────
```

**¿Por qué timer absoluto?**
- El cliente no puede manipular un `server_now + 180s`: incluso si falsifica su reloj local, el servidor usa `time.now_unix_ms()` del pod en el cálculo de `remaining`.
- Igual que `active_session.expires_at` en DynamoDB (ver spec de persistencia), el valor almacenado es el _instante de expiración_, no el _tiempo restante_, lo que hace el cálculo idempotente ante reinicios del pod.

**Reconexión durante DOWNED:**

```
  on reconnect(player_id, session_token):
      p = sessions.get(player_id)
      if p == null:                        // pod murió: recuperar de DynamoDB
          p = load_downed_session(player_id)

      if p.state == DOWNED:
          remaining = p.timer_abs - time.now_unix_ms()
          if remaining <= 0:
              p.state = ELIMINATED
          send_state_snapshot(player_id, p)  // cliente recibe remaining real
```

**Almacenamiento de `timer_abs` ante caída del pod:**
El `MatchStateAccumulator` (en memoria del pod) escribe `timer_abs` en un checkpoint ligero de Redis (`DOWNED:<match_id>:<player_id> = <timer_abs>`) con TTL de 4 minutos. Si Agones reasigna el pod, el servidor entrante lee Redis primero, luego DynamoDB si Redis expiró.

> **Nota de acoplamiento:** Este checkpoint de Redis es el mismo proceso de lectura-reconexión que `MULTIPLAYER_TECHNICAL_SPEC.md §3.4` usa para el lease de sesión, extendiendo su patrón sin duplicar infraestructura.

### 2.4 Interrupción por REVIVE

```
  on revive_attempt(healer_id, target_id, item_sk):
      // 1. Validar que el Healer está en ACTIVE
      // 2. Validar raycast (§4.3)
      // 3. Validar que target está en DOWNED, no ELIMINATED
      // 4. Validar ítem: state == OWNED, item_def en whitelist de revive
      if all_valid:
          target.state   = ACTIVE
          target.hp      = 0.3 * target.max_hp          // 30 % HP al revivir
          downed_timers.remove(target_id)
          redis.del("DOWNED:<match_id>:<target_id>")
          accumulator.items_consumed.append(item_sk)    // se aplica en MATCH_END
          broadcast(PLAYER_REVIVED, target_id, new_hp)
```

La instrucción `accumulator.items_consumed` garantiza que el consumo del ítem de revive se consolide en la misma `TransactWriteItems` de `MATCH_END`, sin una escritura en caliente durante el combate.

---

## 3. Mecánicas Espaciales de Clases (AR Hitboxes)

Todas las validaciones corren en el servidor. El cliente envía `ActionIntent` (ver §5.1); el servidor calcula con las posiciones 3D relativas al `CloudAnchorNode`.

### 3.1 Sistema de Coordenadas

Las posiciones son siempre **relativas al CloudAnchor**, en centímetros (`int32`), exactamente el formato del campo `PositionX/Y/Z` del payload UDP (`MULTIPLAYER_TECHNICAL_SPEC.md §4.1`). El servidor nunca acepta posiciones globales del cliente.

```
  pos_relativa_cm = pos_local_player - pos_cloud_anchor
  distancia_m     = sqrt(Δx² + Δy² + Δz²) / 100.0   // conversión cm → m
```

### 3.2 Clase Guerrero (STRIKING) — Melee

| Parámetro | Valor | Justificación |
|-----------|-------|---------------|
| Rango válido | `d < 2.0 m` | Combate cuerpo a cuerpo en espacio físico real |
| Tolerancia de latencia | `+0.3 m` (lag compensation buffer) | Cubre RTT de 50 ms a 30 Hz con velocidad de caminata de 1.5 m/s |
| Ventana de golpe | 2 ticks = **66.6 ms** | El cliente puede adelantar el input 1 tick |
| Generación de aggro | `base_damage * aggro_multiplier` | Ver tabla de aggro §3.5 |

**Algoritmo de validación server-side:**

```
  on strike_intent(warrior_id, target_id, tick_client):
      pos_w  = players[warrior_id].position_cm
      pos_t  = players[target_id].position_cm
      dist_m = euclidean_cm(pos_w, pos_t) / 100.0

      // Lag compensation: retroceder el snapshot al tick del cliente
      lag_ticks = server_tick - tick_client
      if lag_ticks > 2: return MISS("stale_input")

      compensated_pos_t = interpolate_back(target_id, lag_ticks)
      dist_comp = euclidean_cm(pos_w, compensated_pos_t) / 100.0

      if dist_comp <= 2.3:     // 2.0 + 0.3 tolerancia
          return HIT(calculate_damage(warrior_id, target_id))
      else:
          return MISS("out_of_range")
```

**Aggro generado:** el `aggro_score` del Guerrero sobre el Boss aumenta en `damage * 1.5`. Esto hace que el Boss priorice al Guerrero sobre el Healer, protegiendo al soporte (ver §4 para la lógica de targeting del Boss).

### 3.3 Clase Mago (CLINCH) — Rango

| Parámetro | Valor |
|-----------|-------|
| Rango mínimo | `d >= 2.0 m` (no melee, separación obligatoria) |
| Rango máximo | `d <= 15.0 m` |
| Línea de visión | Raycast servidor contra malla de obstáculos |
| Tiempo de canalización (cast time) | Configurable por `skill_id`, entre `500 ms` y `3000 ms` |
| Interrupción de casteo | Cualquier daño recibido durante el canal cancela la habilidad |

**Validación de línea de visión:**

```
  on cast_start(mage_id, skill_id, target_coord_cm):
      if not los_check(mage_id, target_coord_cm):
          return CAST_FAIL("no_los")
      cast_timer = CastTimer(
          caster    = mage_id,
          skill     = skill_id,
          target    = target_coord_cm,
          expires   = server_now + skills[skill_id].cast_ms
      )
      active_casts[mage_id] = cast_timer

  on cast_interrupted(mage_id):    // llamado desde on_damage_received
      if mage_id in active_casts:
          del active_casts[mage_id]
          notify(mage_id, CAST_INTERRUPTED)

  on tick():
      for mage_id, cast in active_casts.items():
          if server_now >= cast.expires:
              resolve_cast(cast)   // aplica efecto, descuenta cooldown, añade al accumulator
```

**`los_check`:** raycast entre la posición del Mago y `target_coord_cm` contra la lista de `EnvironmentObstacles` transmitida en el SYNC_RESP inicial. El servidor mantiene la AABB de cada obstáculo en memoria del pod; no hay consulta a DynamoDB.

### 3.4 Clase Healer (GRAPPLE) — Soporte

El Healer no ataca; su mecánica principal es **apuntar la cámara hacia un aliado**. El cliente envía el `forward_vector_cm` de la cámara; el servidor calcula si ese rayo intersecta la hitbox del aliado objetivo.

**Algoritmo de raycasting para cura/revive:**

```
  on heal_intent(healer_id, skill_id, forward_vec_cm):
      ray_origin = players[healer_id].position_cm
      ray_dir    = normalize(forward_vec_cm)

      // Buscar el aliado más cercano al rayo dentro del rango de cura
      best_target = null
      best_dot    = 0.87   // cos(30°) — cono de apuntado de ±30°

      for ally_id, ally in players.items():
          if ally_id == healer_id: continue
          if ally.state not in (ACTIVE, DOWNED): continue

          to_ally = normalize(ally.position_cm - ray_origin)
          dot     = dot_product(ray_dir, to_ally)
          dist_m  = euclidean_cm(ray_origin, ally.position_cm) / 100.0

          if dot >= best_dot and dist_m <= 10.0:
              best_target = ally_id
              best_dot    = dot

      if best_target == null:
          return HEAL_FAIL("no_target_in_cone")

      apply_heal(healer_id, best_target, skill_id)
```

**Cálculo de XP asíncrona por puntos de curación efectivos:**

La cura efectiva se define como `min(heal_amount, ally.max_hp - ally.hp)`. Curar a un aliado con HP lleno no genera XP (evita el exploit de spam de cura sobre aliados sanos para farmear XP).

```
  def apply_heal(healer_id, target_id, skill_id):
      raw_heal   = skills[skill_id].heal_power
      ally_gap   = players[target_id].max_hp - players[target_id].hp
      effective  = min(raw_heal, ally_gap)

      players[target_id].hp += effective

      // XP acumulada de forma asíncrona en el accumulator
      // NO escribe en DynamoDB aquí (regla de 0 escrituras en caliente)
      accumulator.xp_delta[healer_id] += effective * XP_PER_HEAL_POINT  // 0.5 XP/HP
      accumulator.damage_dealt[healer_id] += effective   // field "damage_dealt" reutilizado
                                                         // como "effective_healing"
                                                         // discriminado por class en MATCH_END
```

> `accumulator.damage_dealt` cubre tanto daño de Guerrero/Mago como curación del Healer, discriminados en `MATCH_END` por el `primary_style` del jugador. Así el campo `damage_dealt` de `MatchResult.performance` es consistente con el esquema existente sin añadir campos nuevos.

### 3.5 Tabla de Aggro y Targeting del Boss

El Boss selecciona objetivo cada **5 ticks (166 ms)**:

```
  boss.target = argmax(players, key=lambda p: p.aggro_score if p.state == ACTIVE)
```

| Acción | Aggro generado |
|--------|---------------|
| Golpe melee (Guerrero) | `damage × 1.5` |
| Hechizo de área (Mago) | `damage × 1.0` |
| Cura aplicada (Healer) | `heal_effective × 0.8` |
| Taunt (habilidad Guerrero especial) | `+500 flat` |
| DOWNED | `aggro_score = 0` (el Boss lo ignora) |

El aggro decae exponencialmente: `aggro -= aggro * 0.05` por tick cuando el jugador no genera amenaza.

---

## 4. Flujo del Game Loop de Instancia (Combate vs. Boss)

### 4.1 Diagrama de Flujo Completo

```
FASE 1 — SETUP
──────────────────────────────────────────────────────────────────────────
  MatchMaker asigna GameServer (Agones) ──► CloudAnchorID distribuido
  Todos los clientes resuelven el Anchor  ──► state = READY
  Conteo de jugadores completo            ──► match_start emitido

FASE 2 — SPAWN DEL BOSS
──────────────────────────────────────────────────────────────────────────
  Servidor elige spawn_point relativo al CloudAnchor (calculado en el servidor)
  Boss inicializado:
    hp           = boss_template.max_hp
    aggro_table  = {}
    phase        = PHASE_1
  Broadcast ENTITY_SPAWN { entity_id, position_cm, entity_type=ENEMY }
  Boss aparece en CloudAnchorNode/EntitiesGroup en todos los clientes

FASE 3 — BUCLE DE COMBATE (30 Hz / 33.3 ms por tick)
──────────────────────────────────────────────────────────────────────────
  ┌─────────────────────────────────────────────────────────────────────┐
  │  INPUT COLLECTION  (ticks 0–5 ms)                                  │
  │    Servidor recibe ActionIntents del frame anterior por UDP         │
  │    Encola por player_id (descarta duplicados por PacketID)          │
  ├─────────────────────────────────────────────────────────────────────┤
  │  SIMULATION  (ticks 6–20 ms)                                        │
  │    1. Procesar cada ActionIntent:                                    │
  │       a. Validar estado (ACTIVE / cooldown / recursos)              │
  │       b. Validar hitbox / LOS / raycast (§3)                        │
  │       c. Calcular daño/cura → aplicar a HP                          │
  │       d. Actualizar aggro_table                                      │
  │       e. Acumular xp_delta, damage_dealt, etc. en accumulator       │
  │    2. Boss AI (cada 5 ticks):                                        │
  │       a. Seleccionar target (argmax aggro)                           │
  │       b. Calcular acción del Boss (ataque, patrón de fase)          │
  │       c. Aplicar daño a jugadores                                    │
  │       d. Comprobar transición de fase                                │
  │    3. Procesar timers DOWNED                                         │
  │    4. Comprobar condición de victoria (boss.hp <= 0)                │
  ├─────────────────────────────────────────────────────────────────────┤
  │  BROADCAST  (ticks 21–30 ms)                                        │
  │    Serializar WorldState → paquete UPDATE (< 512 bytes)             │
  │    Enviar por UDP a todos los clientes                               │
  │    (posiciones relativas al CloudAnchor, nunca globales)            │
  └─────────────────────────────────────────────────────────────────────┘
  loop hasta boss.hp <= 0  OR  all_players.state == ELIMINATED

FASE 4 — BOSS DERROTADO
──────────────────────────────────────────────────────────────────────────
  Broadcast BOSS_DEFEATED
  Estado players → MATCH_RESULT
  Sellar MatchStateAccumulator (no más mutaciones)
  Ejecutar LOOT DISTRIBUTION (§6)
  Ejecutar MATCH_END settlement (§6.3)

FASE 5 — CLEANUP
──────────────────────────────────────────────────────────────────────────
  GameServer notifica a Agones: estado = FINISHED
  Agones libera el pod para reasignación
```

### 4.2 Fases del Boss y Transición

| Fase | HP % | Cambio de comportamiento |
|------|------|--------------------------|
| `PHASE_1` | 100–60 % | Ataques simples, 1 target |
| `PHASE_2` | 59–30 % | AOE ocasional, aggro reset |
| `PHASE_3` | 29–0 % | AOE continuo, velocidad x1.5 |

La transición de fase emite un evento especial que los clientes usan para cambiar la animación del Boss, sin que el cliente controle la lógica.

---

## 5. Payloads UDP del Game Loop

### 5.1 ActionIntent (Cliente → Servidor)

Nuevo tipo de paquete: `0x05 ACTION_INTENT`.

```
Byte 0-1  : PacketID      (uint16_le)
Byte 2    : PacketType    (0x05)
Byte 3    : PlayerID_lo   (uint8)   // los 8 bits bajos del PlayerID
Byte 4    : Tick          (uint8)   // tick del cliente (módulo 256, para lag comp.)
Byte 5    : ActionType    (uint8)
              0x01 = MELEE_STRIKE
              0x02 = CAST_START
              0x03 = CAST_CANCEL
              0x04 = HEAL_APPLY
              0x05 = REVIVE_APPLY
              0x06 = SKILL_USE     // habilidad activa genérica
Byte 6-7  : TargetID      (uint16_le)  // player_id o entity_id del objetivo
Byte 8-11 : TargetX       (int32_le)   // posición 3D del objetivo (cm, relativa al anchor)
Byte 12-15: TargetY       (int32_le)
Byte 16-19: TargetZ       (int32_le)
Byte 20   : SkillSlot     (uint8)   // índice 0-7 del slot del loadout equipado
Byte 21-22: ForwardVecX   (int16_le) // forward vector normalizado × 32767 (q15)
Byte 23-24: ForwardVecY   (int16_le)
Byte 25-26: ForwardVecZ   (int16_le)
Byte 27-29: reserved      (3 bytes, cero)
```

**Tamaño fijo: 30 bytes.** Muy por debajo del límite de 512 bytes.

### 5.2 Esquema JSON del Payload de Habilidad (Debug / Logging)

```json
{
  "packet_id": 5291,
  "packet_type": "ACTION_INTENT",
  "player_id": 3,
  "tick": 84,
  "action": {
    "type": "CAST_START",
    "skill_slot": 1,
    "skill_id": "mage_fireball_01",
    "target": {
      "entity_id": 101,
      "position_cm": { "x": 312, "y": 0, "z": -88 }
    },
    "forward_vector": { "x": 0.71, "y": 0.0, "z": -0.71 },
    "class": "CLINCH"
  }
}
```

Campos canonizados:

| Campo | Tipo | Descripción |
|-------|------|-------------|
| `action.class` | `combatStyle` enum (`STRIKING`/`CLINCH`/`GRAPPLE`) | Clase del jugador; reusa el enum de `_common.json` |
| `action.skill_id` | string | ID del catálogo de habilidades |
| `action.target.position_cm` | `{x, y, z}` int32 | Posición relativa al CloudAnchor en cm |
| `action.forward_vector` | `{x, y, z}` float normalizado | Solo requerido en `HEAL_APPLY` y `REVIVE_APPLY` |

### 5.3 SkillResolution (Servidor → Clientes)

Nuevo tipo: `0x06 SKILL_RESULT`. Emitido en el tick de resolución.

```json
{
  "packet_type": "SKILL_RESULT",
  "tick": 85,
  "caster_id": 3,
  "target_id": 101,
  "result": "HIT",
  "value": 47,
  "effect": "FIREBALL_IMPACT",
  "new_target_hp": 213,
  "aggro_delta": 47
}
```

`result` puede ser: `HIT` | `MISS` | `BLOCKED` | `CAST_INTERRUPTED` | `HEAL_APPLIED` | `REVIVE_APPLIED` | `INVALID` (con `reason` adicional en debug).

---

## 6. Distribución de Botín y Economía (Loot Distribution)

### 6.1 Economía Dual — Monedas

La separación monetaria es un requisito de negocio y legal (regulaciones de juego).

| Moneda | Código (enum exacto) | Origen | Uso | Impacto en stats |
|--------|---------------------|--------|-----|-----------------|
| **Oro** | `SHARD` | Matar enemigos, curar, defender | Ítems de juego, armamento | **Sí** |
| **Rift Token** | `RIFT_TOKEN` | Compra real (IAP) | Cosméticos 2.5D exclusivamente | **No** |
| **Crédito** | `CREDIT` | Eventos, logros, pase de temporada | Catálogo mixto (no afecta poder) | Controlado |

> `RIFT_TOKEN` **nunca** puede comprarse con `SHARD` ni con `CREDIT`. No existe ruta de conversión. Esta regla debe estar codificada como validación en el backend, **no como convención de cliente**.

### 6.2 Fórmulas de Recompensa por Boss

Las recompensas se calculan con los datos del `MatchStateAccumulator` al momento de sellar (`MATCH_END`).

**XP individual:**
```
xp_earned = BASE_BOSS_XP
           + (damage_dealt_by_player / total_damage_dealt) * DAMAGE_BONUS_XP
           + (effective_healing_by_player / total_effective_healing) * HEAL_BONUS_XP
           + PARTICIPATION_BONUS                        // por estar ACTIVE al morir el Boss
```

Valores de referencia:
- `BASE_BOSS_XP` = 500
- `DAMAGE_BONUS_XP` = 1000
- `HEAL_BONUS_XP` = 800
- `PARTICIPATION_BONUS` = 200 (0 si el jugador está ELIMINATED o DOWNED)

**Oro (`SHARD`) individual:**
```
shard_reward = BOSS_BASE_SHARD
             + mvp_bonus   (si el jugador tuvo más damage_dealt: +200 SHARD)
             + healer_bonus (si fue Healer con effective_healing > threshold: +150 SHARD)
```

**Ítems de botín:** el servidor tira una tabla de loot determinista (seed = `hash(match_id + player_id)`). Máximo **12 ítems** por jugador por partida (límite de `MatchResult.rewards.items`).

### 6.3 Flujo Transaccional de MATCH_END (Loot Distribution)

```
──────────────────────────────────────────────────────────────────────────
  SERVIDOR — al derrotar al Boss
──────────────────────────────────────────────────────────────────────────

  1. SELLAR el MatchStateAccumulator
     - No más mutaciones. Todos los xp_delta, items_granted[], items_consumed[],
       currency_deltas{} quedan fijos.

  2. GENERAR operation_id = hash(match_id + "SETTLE")

  3. Para cada jugador elegible (state != SERVER_ABORT):

     a. Calcular xp_earned, shard_reward, loot_items (§6.2)

     b. Construir lote de TransactWriteItems:
        ┌─────────────────────────────────────────────────────────────┐
        │ Put    IDEM#settle_<match_id>_<player_id>                   │
        │        ConditionExpression: attribute_not_exists(PK)        │
        ├─────────────────────────────────────────────────────────────┤
        │ Update PLAYER#<uuid>  PROFILE                               │
        │        ADD xp += xp_earned                                  │
        │        SET level = new_level (si xp >= xp_to_next)         │
        │        REMOVE active_session                                │
        │        ADD version += 1                                     │
        ├─────────────────────────────────────────────────────────────┤
        │ Update PLAYER#<uuid>  CURRENCY#SHARD                        │
        │        ADD bal += shard_reward                              │
        │        ADD lifetime_earned += shard_reward                  │
        │        ConditionExpression: attribute_exists(PK)            │
        ├─────────────────────────────────────────────────────────────┤
        │ Put    PLAYER#<uuid>  ITEM#<def>#<instance_id>  (×N items) │
        │        ConditionExpression: attribute_not_exists(PK)        │
        │        acquired_via = "MATCH_REWARD"                        │
        ├─────────────────────────────────────────────────────────────┤
        │ Update SQUAD#<uuid>  STATS#S<season>#SHARD#<h>             │
        │        ADD invasions_repelled += 1                          │
        │        ADD total_damage_dealt += contribution               │
        ├─────────────────────────────────────────────────────────────┤
        │ Put    PLAYER#<uuid>  MATCH#<ts_desc>#<match_id>           │
        │        outcome = "INVASION_REPELLED"                        │
        │        performance = { xp_earned, damage_dealt, ... }      │
        │        rewards = { currencies: {SHARD: N}, items: [...] }  │
        │        ttl = now_unix_seconds + 30*86400                   │
        │        settlement_id = operation_id                         │
        └─────────────────────────────────────────────────────────────┘

     c. Si lote > 25 ítems: partir en sub-lotes con sub-operation_id = 
        hash(match_id + "SETTLE_" + player_id + "_" + batch_index)

     d. TransactWriteItems()
        - Si ConditionalCheckFailed en ítem 0 (IDEM lock):
          → "ya liquidado" — continuar con el siguiente jugador
        - Si ConditionalCheckFailed en otro ítem:
          → Error real — reintentar hasta 3 veces con backoff 50/150/400 ms
          → Si falla 3 veces: marcar player settlement como FAILED,
            encolar en cola de compensación fuera de banda

  4. Broadcast MATCH_RESULT a todos los clientes

  5. Notificar a Agones: estado = FINISHED
```

**Diseño anti-explotación del botín:**
- Cada `instance_id` generado es `hash(match_id + player_id + item_index)` → reproducible, único globalmente.
- La condición `attribute_not_exists(PK)` en el Put del ítem impide materializar duplicados incluso si el pod falla y Agones reintenta.
- El job diario del Lakehouse (`GSI1`: `ITEMDEF# → propietarios`) detecta cualquier instancia duplicada que hubiera escapado.

---

## 7. Economía de Tienda y Doble Validación de IAP

### 7.1 Flujo de Compra de `RIFT_TOKEN` (Moneda Dura)

```
Cliente                Backend (Go)              Google Play / Apple
  │                        │                              │
  │ 1. initiate_purchase() │                              │
  │───────────────────────►│                              │
  │                        │ 2. create_pending_order()   │
  │                        │──────────────────────────────────────────────┐
  │                        │   (DynamoDB: ORDER#<order_id> state=PENDING) │
  │                        │──────────────────────────────────────────────┘
  │ 3. purchase_token      │                              │
  │◄───────────────────────│                              │
  │                        │                              │
  │ 4. user completes IAP  │                              │
  │──────────────────────────────────────────────────────►│
  │                        │                              │
  │ 5. receipt             │                              │
  │◄───────────────────────────────────────────────────────│
  │                        │                              │
  │ 6. submit_receipt()    │                              │
  │ (receipt, order_id)    │                              │
  │───────────────────────►│                              │
  │                        │ 7. verify_receipt()          │
  │                        │─────────────────────────────►│
  │                        │                              │
  │                        │ 8. validation_result        │
  │                        │◄─────────────────────────────│
  │                        │                              │
  │                        │ 9. Si válido:                │
  │                        │    TransactWriteItems:       │
  │                        │    - UPDATE CURRENCY#RIFT_TOKEN ADD bal += amount
  │                        │    - PUT ORDER#<id> state=COMPLETED
  │                        │    - PUT IDEM#receipt_<receipt_hash>
  │                        │      (previene replay del mismo receipt)
  │                        │                              │
  │ 10. purchase_complete()│                              │
  │◄───────────────────────│                              │
```

**Doble validación:**
1. **Validación con la tienda** (paso 7): el backend llama directamente a la API de Google Play Developer API v3 (`purchases.products.get`) o Apple App Store Server API con el `transactionId`. Nunca confía en la validación del cliente.
2. **Validación de idempotencia** (paso 9, ítem 3): el `Put IDEM#receipt_<hash>` con `attribute_not_exists(PK)` impide que el mismo receipt sea redimido dos veces, incluso si el cliente lo reenvía.

### 7.2 Regla de Separación Cosmético/Gameplay

```
  on shop_purchase(player_id, item_def, currency_used):
      item_catalog = catalog.get(item_def)

      if item_catalog.affects_stats == true:
          // Solo puede comprarse con SHARD
          if currency_used != "SHARD": return PURCHASE_DENIED("wrong_currency")

      if item_catalog.is_cosmetic == true:
          // Solo puede comprarse con RIFT_TOKEN
          if currency_used != "RIFT_TOKEN": return PURCHASE_DENIED("wrong_currency")

      // RIFT_TOKEN nunca se convierte a SHARD ni CREDIT en ninguna ruta
      if convert_request(from="RIFT_TOKEN"): return DENIED("no_conversion_allowed")
```

---

## 8. Criterios de Aceptación Técnicos

### 8.1 Anti-Cheat

| Ataque | Mitigación del servidor |
|--------|------------------------|
| **Teleport hack** | Posición del cliente ignorada. El servidor solo acepta `ActionIntent` y usa su propia copia de posición |
| **Speed hack** | Velocidad máxima interpolada = 3 m/s. Si un jugador "se mueve" más, su posición se clampea |
| **HP manipulation** | HP nunca se lee del cliente. Solo existe en el `PlayerState` del servidor |
| **Damage inflation** | Daño calculado server-side; el cliente solo envía el `skill_slot` |
| **Timer hack (DOWNED)** | `timer_abs` calculado con `server_now`. El cliente nunca envía el tiempo restante |
| **Receipt replay (IAP)** | `IDEM#receipt_<hash>` con `attribute_not_exists(PK)` |
| **Item duplication** | `instance_id = hash(match_id + player_id + idx)` + `attribute_not_exists(PK)` en cada Put |
| **Double spend** | `ConditionExpression: bal >= :amount` en toda deducción de moneda |

### 8.2 Reconexión durante DOWNED

```
  on reconnect(player_id, session_token):
      1. Verificar session_token contra active_session.match_id en DynamoDB
      2. Leer timer_abs desde Redis (TTL 4 min)
         Si no existe en Redis → jugador expiró → state = ELIMINATED
      3. remaining_ms = timer_abs - server_now
      4. Enviar SYNC_RESP con:
         { state: DOWNED, hp: 0, remaining_ms: remaining_ms }
      5. Añadir de nuevo a downed_timers
```

El cliente recibe el tiempo restante real calculado por el servidor. No puede falsificarlo.

### 8.3 Integridad Económica — SLAs

| SLA | Objetivo |
|-----|----------|
| 0 duplicados de ítem tras 10.000 partidas simuladas | Test de integración con GSI1 |
| 0 saldos negativos bajo 1.000 consumos concurrentes | Test de carga (ADD + ConditionExpression) |
| Latencia de liquidación MATCH_END p99 | < 200 ms |
| Validación IAP (receipt → crédito acreditado) | < 3 s p95 |
| Rechazo de receipt reusado | 100 % (IDEM lock) |

---

## 9. Riesgos Abiertos y Decisiones Pendientes

| Riesgo | Impacto | Decisión necesaria |
|--------|---------|-------------------|
| Redis no disponible para `timer_abs` | Jugador DOWNED reconecta sin saber cuánto le queda | ¿Aceptar pérdida del timer y reiniciar los 180s? ¿O ELIMINATED inmediato? |
| Boss kill simultáneo con pod crash | Botín se pierde si el pod muere entre la derrota y el MATCH_END | Checkpoint de `BOSS_KILLED` en Redis antes de liquidar |
| Latencia de la tabla de loot > 200 ms | Jugadores esperan pantalla de resultado | Liquidación asíncrona: mostrar resultado visual inmediato, confirmar ítems en un segundo paso |
| `effective_healing` mapeado a `damage_dealt` | Confusión en el Lakehouse | Añadir campo `healing_dealt` en `MatchResult.performance` en una iteración futura |
| Contabilización de `invasions_repelled` por escuadrón | Si cada jugador sumara +1, la suma agregada del escuadrón contaría N invasiones por una sola | **Resuelto en implementación:** solo el `player_id` más bajo del escuadrón (determinista, reproducible ante reintentos) incrementa `invasions_repelled`; el resto suma 0. Ver `economy/loot.go:countsInvasion`. Limitación: el modelo actual asume **un escuadrón por instancia** (`acc.SquadID` único). Partidas multi-escuadrón requerirán agrupar el conteo por `squad_ref` de cada jugador. |

---

**Documento elaborado por:** Game Systems Architect / Lead Gameplay Programmer  
**Versión:** 1.0 | **Fecha:** 31 Agosto 2026  
**Estado:** Pendiente de aprobación de reglas de negocio y arquitectura del Game Loop
