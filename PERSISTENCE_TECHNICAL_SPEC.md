# TECHNICAL SPEC - Persistencia y Progresión PixelRift
## Esquema NoSQL de Baja Latencia + Pipeline Lakehouse

---

## 1. Visión del Módulo

Sistema de persistencia que almacena **perfiles de jugador**, **inventarios dinámicos** y **estadísticas de escuadrón**, con latencia de lectura p99 < 20 ms desde el backend autoritativo, y exportación asíncrona de telemetría a un Data Lake para análisis offline.

### Principio de diseño rector

El servidor de juego (tick 30 Hz, ver `MULTIPLAYER_TECHNICAL_SPEC.md`) **nunca escribe en la ruta caliente del combate**. La base de datos operativa se toca en tres momentos: `MATCH_JOIN` (lectura), `MATCH_END` (escritura en lote transaccional) y acciones explícitas de inventario del jugador (transaccional). Todo lo demás va por Streams al Lakehouse.

---

## 2. Decisión de Motor: DynamoDB (Single-Table Design)

| Criterio | DynamoDB | Firestore | Decisión |
|----------|----------|-----------|----------|
| Latencia p99 punto-lectura | 5-10 ms | 30-80 ms | **DynamoDB** |
| Transacciones multi-ítem | `TransactWriteItems` (25 ítems, ACID) | Transacciones con reintentos, más latencia | **DynamoDB** |
| CDC nativo hacia analítica | DynamoDB Streams + Firehose | Firestore→BigQuery (extensión) | **DynamoDB** |
| Escritura condicional atómica | `ConditionExpression` nativa | Sí, pero por documento completo | **DynamoDB** |
| Coste a escala de escritura burst | WCU/on-demand predecible | Coste por operación más alto | **DynamoDB** |

**Elegido: Amazon DynamoDB, tabla única (`pixelft-core`) con overloaded keys.**

Motivo del single-table: los patrones de acceso de progresión son navegaciones jerárquicas (perfil → inventario → escuadrón). Una tabla con PK/SK sobrecargadas resuelve "traer todo el estado del jugador" en **una** `Query` en lugar de 3 round-trips, que es lo que domina el tiempo de `MATCH_JOIN`.

Riesgo asumido: el single-table complica las migraciones de esquema y la legibilidad. Se mitiga con un módulo de acceso a datos (repository layer) que es el único que conoce la forma de las claves, y con `entity_version` en cada ítem.

---

## 3. Diseño de Esquema (Data Modeling)

### 3.1. Tabla principal `pixelft-core`

| Atributo | Tipo | Rol |
|----------|------|-----|
| `PK` | String | Partition Key |
| `SK` | String | Sort Key |
| `entity_type` | String | Discriminador (`PROFILE`, `ITEM`, `SQUAD`, `MEMBER`) |
| `entity_version` | Number | Versión del **esquema** del documento |
| `version` | Number | Contador de **bloqueo optimista** |
| `updated_at` | Number | Epoch ms |
| `gsi1pk` / `gsi1sk` | String | Claves de `GSI1`. Solo presentes en documentos `ITEM` (índice esparso) |

### 3.2. Mapa de claves

```
┌──────────────────────┬───────────────────────────┬──────────────────────────────┐
│ Entidad              │ PK                        │ SK                           │
├──────────────────────┼───────────────────────────┼──────────────────────────────┤
│ PlayerProfile        │ PLAYER#<player_uuid>      │ PROFILE                      │
│ PlayerStats (season) │ PLAYER#<player_uuid>      │ STATS#S<season>              │
│ InventoryItem        │ PLAYER#<player_uuid>      │ ITEM#<item_def>#<instance_id>│
│ InventoryCounter     │ PLAYER#<player_uuid>      │ CURRENCY#<currency_code>     │
│ SquadMetadata        │ SQUAD#<squad_uuid>        │ META                         │
│ SquadStats (season)  │ SQUAD#<squad_uuid>        │ STATS#S<season>              │
│ SquadMember          │ SQUAD#<squad_uuid>        │ MEMBER#<player_uuid>         │
│ MatchResult (TTL 30d)│ PLAYER#<player_uuid>      │ MATCH#<ts_desc>#<match_id>   │
│ IdempotencyLock      │ IDEM#<operation_id>       │ LOCK                         │
└──────────────────────┴───────────────────────────┴──────────────────────────────┘
```

### 3.3. Anti Hot-Partition

Tres decisiones concretas:

1. **PK = `PLAYER#<uuid>`, nunca un rango secuencial.** El UUIDv4 distribuye uniformemente sobre el espacio de hash. Se prohíbe explícitamente `PLAYER#<autoincrement>` o PK derivadas de timestamp, que concentran escrituras en la última partición.

2. **Escuadrón: PK propia, no anidada en el jugador.** Un escuadrón popular (100 miembros escribiendo stats) sería una partición caliente si colgara del perfil del líder. Al ser `SQUAD#<uuid>` con SK por miembro, la escritura del contador agregado del escuadrón se resuelve por **write sharding**:

```
SQUAD#<squad_uuid>  SK = STATS#S<season>#SHARD#<0..9>
```
   El servidor escribe en `SHARD#<hash(player_uuid) % 10>`. La lectura del total agregado hace una `Query` de 10 ítems y suma en aplicación. Esto convierte un ítem con 100 escritores concurrentes en 10 ítems con ~10, quedando lejos del límite de 1000 WCU/partición.

3. **Leaderboards NO viven en DynamoDB.** El patrón "top 100 global" es un scan ordenado; forzarlo con un GSI de PK única (`LEADERBOARD#GLOBAL`) crea la peor hot partition posible. Se resuelve con **ElastiCache Redis (Sorted Set)** alimentado desde Streams, y el ranking histórico se calcula en el Lakehouse.

### 3.4. Índice Secundario Global

**Un solo GSI, esparso y con proyección `KEYS_ONLY`.**

| Índice | gsi1pk | gsi1sk | Proyección | Patrón que resuelve |
|--------|--------|--------|------------|---------------------|
| `GSI1` | `ITEMDEF#<item_def>` | `PLAYER#<uuid>` | `KEYS_ONLY` | Auditoría inversa: "¿quién posee el ítem X?" (detección de duplicados) |

Solo los documentos `ITEM` escriben `gsi1pk`/`gsi1sk`. Al ser esparso, el índice contiene inventario y nada más, y la amplificación de escritura queda acotada a las mutaciones de ítem en lugar de aplicarse a toda escritura de la tabla.

`KEYS_ONLY` y no `ALL`: con `ALL`, cada consumo de una poción o cambio de durabilidad duplicaría su coste de escritura al replicar el documento completo al índice. La auditoría solo necesita PK/SK.

**Corrección respecto al borrador inicial.** El diseño previo planteaba un segundo índice invertido `SQUAD#<uuid>` → `PLAYER#<uuid>` para resolver la pertenencia a escuadrón. Es redundante: `squad_ref` ya viaja en el perfil y por tanto lo devuelve la Query de `MATCH_JOIN` (A1), y el roster se obtiene con `Query PK=SQUAD#<id>, SK begins_with MEMBER#` sobre la tabla base (A7). Mantenerlo habría añadido amplificación de escritura a cada actualización de perfil y de miembro sin resolver ningún patrón que no estuviera ya cubierto.

### 3.5. Documentos JSON

**PlayerProfile**
```json
{
  "PK": "PLAYER#7f3a9c21-4e88-4b0a-9d13-6ac2f0e51b77",
  "SK": "PROFILE",
  "entity_type": "PROFILE",
  "entity_version": 1,
  "version": 42,
  "display_name": "NeonRonin",
  "created_at": 1756598400000,
  "updated_at": 1756684800000,
  "last_login_at": 1756684800000,
  "progression": {
    "level": 27,
    "xp": 184320,
    "xp_to_next": 12800,
    "prestige": 1
  },
  "loadout": {
    "primary_style": "STRIKING",
    "secondary_style": "CLINCH",
    "equipped": ["ITEM#gauntlet_mk2#a91f", "ITEM#visor_neon#c3d0"]
  },
  "squad_ref": "SQUAD#1b2c3d4e-5f60-4718-8293-aabbccddeeff",
  "flags": {
    "banned": false,
    "shadow_flagged": false
  }
}
```

**InventoryItem** (un ítem = un documento; sin arrays de tamaño no acotado)
```json
{
  "PK": "PLAYER#7f3a9c21-4e88-4b0a-9d13-6ac2f0e51b77",
  "SK": "ITEM#gauntlet_mk2#a91f4d02",
  "entity_type": "ITEM",
  "entity_version": 1,
  "version": 3,
  "item_def": "gauntlet_mk2",
  "instance_id": "a91f4d02",
  "quantity": 1,
  "stackable": false,
  "bound": true,
  "acquired_at": 1756612800000,
  "acquired_via": "MATCH_REWARD",
  "source_match_id": "m_8f21ba",
  "durability": 88,
  "state": "OWNED",
  "gsi1pk": "ITEMDEF#gauntlet_mk2",
  "gsi1sk": "PLAYER#7f3a9c21-4e88-4b0a-9d13-6ac2f0e51b77"
}
```

Decisión: el inventario **no** es un array dentro del perfil. Un array crece sin cota hacia el límite de 400 KB por ítem, y cada consumo de una poción reescribiría el documento entero (WCU proporcional al tamaño total, no al cambio). Un documento por instancia mantiene la escritura en 1 WCU y habilita `ConditionExpression` por ítem.

Los consumibles apilables usan un único documento con `SK = ITEM#potion_medkit#STACK` y `quantity` mutada con `ADD` atómico.

**Squad**
```json
{
  "PK": "SQUAD#1b2c3d4e-5f60-4718-8293-aabbccddeeff",
  "SK": "META",
  "entity_type": "SQUAD",
  "entity_version": 1,
  "version": 11,
  "name": "Rift Wardens",
  "tag": "RFTW",
  "leader": "PLAYER#7f3a9c21-4e88-4b0a-9d13-6ac2f0e51b77",
  "member_count": 24,
  "max_members": 50,
  "created_at": 1756512000000,
  "join_policy": "INVITE_ONLY"
}
```

```json
{
  "PK": "SQUAD#1b2c3d4e-5f60-4718-8293-aabbccddeeff",
  "SK": "STATS#S3#SHARD#4",
  "entity_type": "SQUAD_STATS_SHARD",
  "shard_id": 4,
  "season": 3,
  "invasions_repelled": 118,
  "invasions_failed": 23,
  "total_damage_dealt": 4820115,
  "updated_at": 1756684800000
}
```

---

## 4. Patrones de Acceso (Read/Write)

### 4.1. Matriz de patrones

| # | Patrón | Operación | Consumo | Frecuencia |
|---|--------|-----------|---------|------------|
| A1 | Cargar estado completo del jugador | `Query PK=PLAYER#<id>` | ~4-8 RCU (eventual) | 1 × `MATCH_JOIN` |
| A2 | Resolver escuadrón de un jugador | leído en A1 (`squad_ref`) | 0 extra | — |
| A3 | Stats agregadas del escuadrón | `Query PK=SQUAD#<id>, SK begins_with STATS#S3#` | ~2 RCU | on-demand (UI) |
| A4 | Persistir fin de partida | `TransactWriteItems` (lote) | ver 4.2 | 1 × `MATCH_END` |
| A5 | Consumir ítem en combate | `UpdateItem` condicional | 1 WCU | eventual, ver 4.3 |
| A6 | Intercambio entre jugadores | `TransactWriteItems` (4 ítems) | 8 WCU | baja |
| A7 | Roster del escuadrón | `Query PK=SQUAD#<id>, SK begins_with MEMBER#` | ~3 RCU | on-demand |
| A8 | Historial de partidas | `Query PK, SK begins_with MATCH#, Limit 20` | ~4 RCU | on-demand |

`MATCH_JOIN` completo = **una** `Query` (A1). Es la razón de existir del single-table.

### 4.2. Escritura en lote al finalizar el combate

La regla es: durante los 30 ticks/s el estado vive **solo en memoria del pod de Agones**. Ninguna escritura a DynamoDB ocurre dentro del bucle de simulación.

```
Combate en curso (in-memory)
  ├─ MatchStateAccumulator
  │    ├─ xp_delta por jugador
  │    ├─ items_granted[] (pendientes)
  │    ├─ items_consumed[] (pendientes)
  │    └─ squad_delta (invasions_repelled, damage)
  │
  ▼  MATCH_END (invasión repelida)
┌──────────────────────────────────────────────────────────────┐
│ 1. Sellar el acumulador (no más mutaciones)                  │
│ 2. Generar operation_id = hash(match_id + "SETTLE")          │
│ 3. TransactWriteItems (por lote de ≤25 ítems):               │
│      • Put   IDEM#<operation_id>  attribute_not_exists(PK)   │
│      • Update PROFILE  xp += Δ, level, version += 1          │
│      • Put    ITEM#... (recompensas, 1 por ítem)             │
│      • Update SQUAD STATS#S3#SHARD#<h> ADD contadores        │
│      • Put    MATCH#<ts>#<match_id> (con TTL 30d)            │
│ 4. Si N > 25 ítems → particionar en varias transacciones,    │
│    cada una con su propio sub-operation_id                   │
│ 5. Ack al pod → liberar GameServer                           │
└──────────────────────────────────────────────────────────────┘
```

**Idempotencia:** el `Put` de `IDEM#<operation_id>` con `attribute_not_exists(PK)` es el guardián. Si el pod muere tras el commit pero antes del ack, Agones reprograma la liquidación y la transacción falla completa con `TransactionCanceledException / ConditionalCheckFailed`. El servidor interpreta ese fallo específico como "ya liquidado" y continúa. Esto convierte una operación no idempotente en idempotente sin coordinación externa.

Coste medido por partida de 10 jugadores: ~1 transacción de 22 ítems ≈ 44 WCU (transaccional cuesta 2×). Frente a escribir cada evento en caliente (30 Hz × 10 jugadores = 300 WCU/s), la reducción es de **~3 órdenes de magnitud**.

**Punto de fallo aceptado y declarado:** si el pod se pierde *antes* de `MATCH_END`, el progreso de esa partida se pierde. Es una decisión consciente: el coste de checkpoints intermedios (WCU + latencia) no justifica proteger ~5 minutos de progreso. Mitigación parcial: checkpoint único a mitad de partida solo para monedas *ganadas*, si el playtesting muestra que la pérdida es percibida como injusta.

### 4.3. Consumo de ítems en combate

Consumir una poción en el tick 412 no puede bloquear el bucle. Flujo:

1. El servidor valida contra su copia en memoria y **aplica el efecto inmediatamente** (respuesta autoritativa al cliente en el mismo tick).
2. Encola el consumo en `items_consumed[]`.
3. La escritura real ocurre en `MATCH_END` dentro de la transacción.

Riesgo: un jugador con 1 poción que juega dos partidas simultáneas podría consumirla dos veces. Se cierra con un **lease de sesión**: al `MATCH_JOIN`, `UpdateItem` sobre el perfil con `ConditionExpression: attribute_not_exists(active_session) OR active_session_expires < :now`, escribiendo `active_session = <match_id>` y TTL de 15 min. Un jugador no puede estar en dos partidas a la vez, así que el inventario tiene un único escritor lógico.

---

## 5. Gestión de Inventario Seguro

### 5.1. Bloqueo optimista (base para toda mutación)

Cada ítem y perfil lleva `version` (Number). Toda escritura es condicional:

```
UpdateItem
  Key: { PK: PLAYER#<id>, SK: ITEM#<def>#<inst> }
  UpdateExpression:    SET quantity = :q, version = :next, updated_at = :now
  ConditionExpression: version = :expected
```

Si otro escritor ganó la carrera, DynamoDB devuelve `ConditionalCheckFailedException`. Política: **3 reintentos con backoff exponencial + jitter** (50/150/400 ms); al cuarto fallo se aborta y se registra en `inventory_conflicts` para alerta. Un pico en esa métrica es señal de bug de concurrencia o de intento de exploit, no ruido.

No se usan bloqueos pesimistas: mantener un lock explícito durante una llamada de red es exactamente el patrón que produce deadlocks cuando un pod muere sin liberarlo.

### 5.2. Intercambio entre jugadores (el caso peligroso)

El exploit clásico es la duplicación por desincronización: A da el ítem, la escritura de A confirma, la de B falla, y el ítem existe en dos lados o desaparece. `TransactWriteItems` lo elimina por construcción: los 4 writes son un único commit ACID.

```
TransactWriteItems([
  # 1. Guardián de idempotencia
  Put    { PK: IDEM#trade_<trade_id>, SK: LOCK }
         ConditionExpression: attribute_not_exists(PK)

  # 2. Retirar del emisor: existe, es suyo, no está bloqueado, versión intacta
  Delete { PK: PLAYER#<A>, SK: ITEM#<def>#<inst> }
         ConditionExpression: attribute_exists(PK)
                          AND #state = :OWNED
                          AND bound = :false
                          AND version = :vA

  # 3. Entregar al receptor: la instancia NO puede existir ya
  Put    { PK: PLAYER#<B>, SK: ITEM#<def>#<inst>, ... , version: 1,
           acquired_via: TRADE, trade_id: <trade_id> }
         ConditionExpression: attribute_not_exists(PK)

  # 4. Rastro de auditoría inmutable
  Put    { PK: TRADE#<trade_id>, SK: RECORD, from: A, to: B, item, ts }
])
```

Las cuatro condiciones importan:
- `attribute_not_exists` en (1) hace el trade idempotente ante reintentos de red.
- `#state = OWNED AND bound = false` impide comerciar ítems equipados, en escrow o vinculados.
- `attribute_not_exists` en (3) impide materializar una instancia duplicada.
- (4) da trazabilidad forense: ante un reporte de duplicación, `TRADE#` reconstruye la cadena de custodia completa.

`instance_id` es la clave del modelo antiduplicación: un ítem no apilable es una **instancia única global**. Dos documentos con el mismo `instance_id` en distintos jugadores es, por definición, corrupción, y `GSI1` (`ITEMDEF#<def>` → jugadores) permite detectarlo con un job diario en el Lakehouse.

### 5.3. Apilables y monedas

Para stacks y monedas no se hace read-modify-write (vulnerable a lost update). Se usa `ADD` atómico con guarda de no-negatividad:

```
UpdateExpression:    ADD quantity :delta          # :delta = -1 al consumir
ConditionExpression: quantity >= :abs_delta
```

DynamoDB serializa `ADD` en el nodo de la partición, así que el contador es correcto bajo concurrencia sin leer antes. La `ConditionExpression` es la que impide el saldo negativo, que es el vector de exploit habitual en economías de juego.

### 5.4. Límites que hay que respetar

`TransactWriteItems` admite **25 ítems** y **4 MB**, y no puede tocar dos veces el mismo ítem en la misma transacción. Por eso la liquidación de `MATCH_END` se particiona en sub-transacciones con `operation_id` propio en lugar de intentar un commit único gigante.

---

## 6. Optimización de Costos y Data Engineering

### 6.1. FinOps: dimensionamiento

| Entorno | Modo de capacidad | Justificación |
|---------|-------------------|---------------|
| dev / QA | On-Demand | Tráfico esporádico; pagar por reserva es puro desperdicio |
| Producción (lanzamiento) | On-Demand, 4-6 semanas | Sin histórico no se puede dimensionar; On-Demand absorbe el pico de lanzamiento sin throttling |
| Producción (estable) | Provisioned + Auto Scaling | Con el patrón diario conocido, Provisioned al p50 + autoscaling cubre el resto |

Estable en detalle:
- Auto Scaling con **target utilization 70%** (margen para la rampa; el escalado de DynamoDB no es instantáneo).
- `min_capacity` al p50 del valle, `max_capacity` = 3× el pico observado como cortacircuitos de gasto.
- **Reserved Capacity** a 1 año sobre la línea base de WCU/RCU, no sobre el pico.
- Un pico predecible (evento de fin de semana) se pre-escala con un cambio programado, no reactivamente.

Ahorros estructurales:
- **TTL en `MATCH#`** (30 días): el borrado por TTL **no consume WCU**. Es la palanca de coste más rentable del diseño; el historial largo vive en S3, que es ~20× más barato por GB.
- **Proyecciones acotadas en GSI:** un GSI con `ALL` sobre el inventario duplica el WCU de cada mutación de ítem. `KEYS_ONLY` / `INCLUDE` mínimo.
- **Nombres de atributo cortos** en documentos de alta cardinalidad: en DynamoDB las claves de atributo cuentan para el tamaño del ítem, y por tanto para RCU/WCU. `q` en lugar de `quantity` en el ítem más escrito no es micro-optimización, es un porcentaje real de la factura.
- **Compresión (gzip → Binary)** solo para blobs > 1 KB de baja frecuencia de lectura (replay metadata). No aplicar a atributos usados en `ConditionExpression`.

Guardarraíles: presupuesto AWS con alerta al 80%, alarma de `ConsumedWriteCapacityUnits` y de `ThrottledRequests > 0`. Throttling sostenido en producción se trata como incidente, no como ajuste de coste.

### 6.2. Pipeline analítico (aislamiento del servidor de juego)

Regla no negociable: **el entorno analítico nunca lee la tabla operativa.** Sin `Scan`, sin jobs de Spark contra DynamoDB. El acoplamiento por lectura es lo que degrada la latencia p99 del juego cuando el equipo de datos lanza una consulta pesada.

```
┌───────────────────┐
│  pixelft-core     │  DynamoDB (operativo, latencia p99 < 20ms)
│  (Streams ON)     │
└─────────┬─────────┘
          │ NEW_AND_OLD_IMAGES  (24h retención, push, sin coste de lectura de tabla)
          ▼
┌───────────────────┐
│  Kinesis Data     │  Fan-out a múltiples consumidores independientes
│  Streams          │
└────┬─────────┬────┘
     │         │
     │         └──────────────► Lambda: proyección a Redis (Sorted Set)
     │                          → leaderboards en tiempo real
     ▼
┌───────────────────┐
│ Kinesis Firehose  │  Buffer 128 MB / 300 s → evita el problema de small files
│ + Lambda transform│  Normaliza NEW/OLD image a filas planas por entity_type
└─────────┬─────────┘
          ▼
┌───────────────────────────────────────────────────────────┐
│  S3 Data Lake  (Parquet + Snappy)                         │
│  s3://pixelft-lake/bronze/entity=PROFILE/dt=2026-08-31/   │
│  s3://pixelft-lake/bronze/entity=ITEM/dt=.../             │
│  s3://pixelft-lake/bronze/entity=SQUAD_STATS/dt=.../      │
└─────────┬─────────────────────────────────────────────────┘
          ▼
┌───────────────────────────────────────────────────────────┐
│  Lakehouse (Apache Iceberg sobre S3)                      │
│  ├─ bronze : append-only, CDC crudo, inmutable            │
│  ├─ silver : Spark (EMR/Glue) — MERGE INTO por PK+SK,     │
│  │           deduplicado, estado actual reconstruido      │
│  └─ gold   : agregados de negocio (retención D1/D7/D30,   │
│              curva de progresión, economía de ítems)      │
└─────────┬─────────────────────────────────────────────────┘
          ▼
   Athena (ad-hoc)  ·  QuickSight (dashboards)  ·  Spark ML (matchmaking, detección de exploits)
```

Decisiones del pipeline:

- **`NEW_AND_OLD_IMAGES`**: sin la imagen previa no se puede calcular el delta de un intercambio ni auditar duplicaciones. Es el requisito que hace posible la detección de exploits.
- **Kinesis Data Streams en lugar de Lambda directo sobre Streams**: permite N consumidores (Firehose al lake + Lambda a Redis + futuro antifraude) sin que uno lento bloquee a los demás.
- **Buffer de Firehose 128 MB / 300 s**: latencia analítica de ~5 min a cambio de ficheros Parquet de tamaño sano. El small-files problem degrada las consultas de Spark más que cualquier optimización posterior.
- **Iceberg y no Parquet plano en silver**: `MERGE INTO` sobre PK+SK es la operación central para reconstruir el estado actual desde un log CDC; Iceberg la soporta con time travel para auditoría.
- **Particionado por `entity` + `dt`**: `entity` primero porque las consultas analíticas casi siempre acotan un tipo de entidad; evita escanear el inventario para calcular retención.

Contrapartida honesta: la cadena Streams → Kinesis → Firehose → Spark introduce ~5-10 min de latencia end-to-end y varias piezas que pueden fallar. Es aceptable porque el consumo es **analítico y offline**. Todo lo que exija tiempo real (leaderboard) sale por la rama de Lambda → Redis, no por el lake.

### 6.3. Coste del pipeline

| Componente | Driver de coste | Control |
|------------|-----------------|---------|
| DynamoDB Streams | Gratis con Kinesis adapter | — |
| Kinesis Data Streams | Shard-hora + PUT payload | On-demand al inicio; shards fijos al conocer el throughput |
| Firehose | GB ingeridos | Transform Lambda descarta atributos irrelevantes antes de S3 |
| S3 | GB-mes | Lifecycle: bronze → Glacier IR a 90 días |
| EMR / Glue | DPU-hora | Batch nocturno con Spot; sin clúster permanente |
| Athena | TB escaneados | Parquet + particionado + `LIMIT` obligatorio en exploración |

---

## 7. Criterios de Aceptación

| SLA | Objetivo | Validación |
|-----|----------|------------|
| Lectura `MATCH_JOIN` (A1) | p99 < 20 ms, 1 sola Query | CloudWatch `SuccessfulRequestLatency` |
| Liquidación `MATCH_END` | p99 < 200 ms | Traza de aplicación |
| Escrituras en ruta caliente | **0** durante el combate | Revisión de código + auditoría de traza |
| Duplicación de ítems | 0 en test de concurrencia (1000 trades paralelos) | Test de integración + `GSI1` |
| Saldo negativo de moneda | 0 casos | Test de carga con consumo concurrente |
| Throttling en producción | 0 sostenido | Alarma `ThrottledRequests` |
| Latencia CDC → lake | < 10 min p95 | Métricas de Firehose |
| Aislamiento analítico | 0 `Scan` desde analítica | Política IAM: analítica sin permiso de lectura en la tabla |

---

## 8. Riesgos Abiertos

| Riesgo | Impacto | Mitigación |
|--------|---------|------------|
| Pérdida de progreso si el pod muere pre-`MATCH_END` | Medio | Aceptado; checkpoint parcial si el playtesting lo exige |
| Rigidez del single-table ante cambios de esquema | Medio | Repository layer + `entity_version` con lectura tolerante |
| Escuadrones > 200 miembros | Bajo hoy | Aumentar shards de stats de 10 a 50 (parámetro, no rediseño) |
| Retención de Streams 24 h | Alto si el pipeline cae > 24 h | Alarma en `GetRecords.IteratorAgeMilliseconds` con umbral 4 h |
| Coste de Kinesis con tráfico bajo | Bajo | On-demand hasta tener throughput medido |

---

## 9. Referencias

- [DynamoDB single-table design (AWS)](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/bp-general-nosql-design.html)
- [Partition key design y write sharding](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/bp-partition-key-design.html)
- [TransactWriteItems](https://docs.aws.amazon.com/amazondynamodb/latest/APIReference/API_TransactWriteItems.html)
- [Optimistic locking con version number](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/DynamoDBMapper.OptimisticLocking.html)
- [DynamoDB Streams + Kinesis](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/kds.html)
- [Apache Iceberg MERGE INTO](https://iceberg.apache.org/docs/latest/spark-writes/)

---

**Documento elaborado por:** Data Engineer / Arquitecto Cloud  
**Versión:** 1.0  
**Fecha:** 31 Agosto 2026  
**Estado:** Pendiente de aprobación del modelo de datos
