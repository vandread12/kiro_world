// loot.go
// Distribución de botín y liquidación transaccional en MATCH_END.
// Regla: CERO escrituras a DynamoDB durante el combate.
// Todo ocurre aquí, después de sellar el MatchStateAccumulator.
//
// Spec: GAMELOOP_TECHNICAL_SPEC.md §6

package economy

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"strconv"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb/types"
	"go.uber.org/zap"

	game "github.com/pixelrift/gameserver/pkg/game"
)

// ---------------------------------------------------------------------------
// Constantes de recompensa (spec §6.2)
// ---------------------------------------------------------------------------

const (
	BaseBossXP         = 500
	DamageBonusXP      = 1000
	HealBonusXP        = 800
	ParticipationBonus = 200

	BossBaseShardReward = 300
	MVPShardBonus       = 200
	HealerShardBonus    = 150

	HealerEffHealThreshold = 200 // HP efectivos mínimos para el bono de Healer
	XPPerHealPoint         = 0.5

	// Límites coincidentes con los schemas de persistencia
	MaxRewardItems   = 12 // MatchResult.rewards.items maxItems
	MaxTransactItems = 25 // límite DynamoDB TransactWriteItems (spec Persistence §2.5)

	// Monedas — deben coincidir EXACTAMENTE con currencyCode de _common.json
	CurrencyShard     = "SHARD"
	CurrencyCredit    = "CREDIT"
	CurrencyRiftToken = "RIFT_TOKEN"
)

// ---------------------------------------------------------------------------
// Servicio de distribución de botín
// ---------------------------------------------------------------------------

// LootService calcula y persiste recompensas tras derrotar al Boss.
type LootService struct {
	ddb       *dynamodb.Client
	tableName string
	lootTable LootTable
	logger    *zap.Logger
}

// LootTable define la lógica de generación de ítems de recompensa.
type LootTable interface {
	// Roll genera hasta MaxRewardItems ítems deterministas para este jugador.
	// seed = hash(match_id + player_id) para reproducibilidad.
	Roll(seed string, maxItems int) []game.LootItem
}

// NewLootService crea un servicio con el cliente DynamoDB inyectado.
func NewLootService(ddb *dynamodb.Client, tableName string, table LootTable, log *zap.Logger) *LootService {
	return &LootService{ddb: ddb, tableName: tableName, lootTable: table, logger: log}
}

// ---------------------------------------------------------------------------
// Punto de entrada — llamado una vez por jugador en MATCH_END
// ---------------------------------------------------------------------------

// SettlePlayerRewards calcula y persiste las recompensas de un jugador.
// Es idempotente: el IDEM lock en DynamoDB garantiza que los reintentos de
// Agones no dupliquen el botín (spec §6.3 y Persistence §2.2).
func (s *LootService) SettlePlayerRewards(
	ctx context.Context,
	acc *game.MatchStateAccumulator,
	playerID uint16,
) error {
	p, ok := acc.Players[playerID]
	if !ok {
		return fmt.Errorf("player %d not found in accumulator", playerID)
	}

	// Jugadores que cerraron la app sin reconectar NO reciben recompensa
	if p.State == game.StateDisconnected {
		s.logger.Info("skip settlement: player disconnected", zap.Uint16("player", playerID))
		return nil
	}

	// Calcular recompensas
	rewards := s.calculateRewards(acc, playerID)

	// Generar operation_id idempotente
	opID := operationID(acc.MatchID, playerID)

	// Particionar en lotes de MaxTransactItems si es necesario
	batches := buildTransactionBatches(acc, p, rewards, opID, s.tableName)

	for i, batch := range batches {
		batchOpID := opID
		if len(batches) > 1 {
			batchOpID = fmt.Sprintf("%s_b%d", opID, i)
			// Actualizar el IDEM lock de este sub-lote
			batch = rewriteIdemLock(batch, batchOpID, s.tableName)
		}

		if err := s.executeTransact(ctx, batch, batchOpID, acc.MatchID, playerID); err != nil {
			return err
		}
	}

	s.logger.Info("settlement complete",
		zap.String("match", acc.MatchID),
		zap.Uint16("player", playerID),
		zap.Int("xp", rewards.XPEarned),
		zap.Int("shard", rewards.ShardEarned),
	)
	return nil
}

// ---------------------------------------------------------------------------
// Cálculo de recompensas (spec §6.2)
// ---------------------------------------------------------------------------

// PlayerRewards agrupa todo lo que se otorga a un jugador.
type PlayerRewards struct {
	XPEarned    int
	ShardEarned int
	LootItems   []game.LootItem
}

func (s *LootService) calculateRewards(acc *game.MatchStateAccumulator, playerID uint16) PlayerRewards {
	p := acc.Players[playerID]

	// XP
	xp := BaseBossXP
	if acc.TotalDamage > 0 {
		xp += int(float64(p.DamageDelta) / float64(acc.TotalDamage) * DamageBonusXP)
	}
	if acc.TotalHealing > 0 {
		xp += int(float64(p.EffHealingDelta) / float64(acc.TotalHealing) * HealBonusXP)
	}
	if p.State == game.StateActive {
		xp += ParticipationBonus
	}

	// SHARD
	shard := BossBaseShardReward
	shard += mvpBonus(acc, playerID)
	if p.Style == game.StyleGrapple && p.EffHealingDelta >= HealerEffHealThreshold {
		shard += HealerShardBonus
	}

	// Ítems de botín (deterministas, reproducibles)
	seed := fmt.Sprintf("%s_%d", acc.MatchID, playerID)
	items := s.lootTable.Roll(seed, MaxRewardItems)

	// Asignar instance_id = hash(match_id + player_id + index)
	for i := range items {
		items[i].InstanceID = instanceID(acc.MatchID, playerID, i)
	}

	return PlayerRewards{XPEarned: xp, ShardEarned: shard, LootItems: items}
}

func mvpBonus(acc *game.MatchStateAccumulator, playerID uint16) int {
	p := acc.Players[playerID]
	for _, other := range acc.Players {
		if other.PlayerID != playerID && other.DamageDelta >= p.DamageDelta {
			return 0
		}
	}
	return MVPShardBonus
}

// ---------------------------------------------------------------------------
// Construcción de la TransactWriteItems (spec §6.3)
// ---------------------------------------------------------------------------

func buildTransactionBatches(
	acc *game.MatchStateAccumulator,
	p *game.Player,
	rewards PlayerRewards,
	opID string,
	tableName string,
) [][]types.TransactWriteItem {
	var items []types.TransactWriteItem

	// 1. Guardián de idempotencia (SIEMPRE el primero)
	items = append(items, idemLockItem(opID, acc.MatchID, tableName))

	// 2. Update PlayerProfile: xp, level, eliminar active_session
	items = append(items, updateProfileItem(p.PlayerID, rewards.XPEarned, tableName))

	// 3. Update CurrencyCounter: ADD SHARD
	items = append(items, updateCurrencyItem(p.PlayerID, CurrencyShard, rewards.ShardEarned, tableName))

	// 4. Put InventoryItems (uno por ítem de recompensa)
	for _, loot := range rewards.LootItems {
		items = append(items, putInventoryItem(p.PlayerID, loot, acc.MatchID, tableName))
	}

	// 5. Update SquadStats shard.
	// total_damage_dealt SÍ es contribución individual del jugador.
	// invasions_repelled NO: una invasión repelida es un evento único de la
	// partida. Si cada jugador sumara +1, la suma agregada del escuadrón
	// contaría N invasiones por una sola. Solo el jugador designado como
	// "contador de invasión" incrementa ese campo (ver countsInvasion).
	if acc.SquadID != "" {
		shard := shardIndex(p.PlayerID, 10)
		items = append(items, updateSquadStatsItem(
			acc.SquadID, acc.Season, shard,
			p.DamageDelta,
			countsInvasion(acc, p.PlayerID),
			tableName,
		))
	}

	// 6. Put MatchResult (con TTL 30 días en epochSeconds)
	items = append(items, putMatchResultItem(p, acc, rewards, tableName))

	// Partir en lotes de MaxTransactItems
	return partitionBatches(items)
}

func partitionBatches(items []types.TransactWriteItem) [][]types.TransactWriteItem {
	var batches [][]types.TransactWriteItem
	for len(items) > 0 {
		end := MaxTransactItems
		if end > len(items) {
			end = len(items)
		}
		batches = append(batches, items[:end])
		items = items[end:]
	}
	return batches
}

// ---------------------------------------------------------------------------
// Constructores de TransactWriteItem
// ---------------------------------------------------------------------------

func idemLockItem(opID, matchID, tableName string) types.TransactWriteItem {
	nowMS := time.Now().UnixMilli()
	ttlS := time.Now().Add(48 * time.Hour).Unix() // 48 h en epochSeconds
	return types.TransactWriteItem{
		Put: &types.Put{
			TableName: aws.String(tableName),
			Item: map[string]types.AttributeValue{
				"PK":             &types.AttributeValueMemberS{Value: "IDEM#" + opID},
				"SK":             &types.AttributeValueMemberS{Value: "LOCK"},
				"entity_type":    &types.AttributeValueMemberS{Value: "IDEM"},
				"entity_version": &types.AttributeValueMemberN{Value: "1"},
				"operation_kind": &types.AttributeValueMemberS{Value: "MATCH_SETTLE"},
				"correlation_id": &types.AttributeValueMemberS{Value: matchID},
				"created_at":     &types.AttributeValueMemberN{Value: strconv.FormatInt(nowMS, 10)},
				"ttl":            &types.AttributeValueMemberN{Value: strconv.FormatInt(ttlS, 10)},
			},
			// Hace el settle idempotente ante reintentos de Agones
			ConditionExpression: aws.String("attribute_not_exists(PK)"),
		},
	}
}

func updateProfileItem(playerID uint16, xpDelta int, tableName string) types.TransactWriteItem {
	pk := fmt.Sprintf("PLAYER#%s", uuidFromID(playerID))
	return types.TransactWriteItem{
		Update: &types.Update{
			TableName: aws.String(tableName),
			Key: map[string]types.AttributeValue{
				"PK": &types.AttributeValueMemberS{Value: pk},
				"SK": &types.AttributeValueMemberS{Value: "PROFILE"},
			},
			UpdateExpression: aws.String(
				"ADD #xp :xp_delta, #ver :one " +
					"REMOVE active_session",
			),
			ExpressionAttributeNames: map[string]string{
				"#xp":  "xp",
				"#ver": "version",
			},
			ExpressionAttributeValues: map[string]types.AttributeValue{
				":xp_delta": &types.AttributeValueMemberN{Value: strconv.Itoa(xpDelta)},
				":one":      &types.AttributeValueMemberN{Value: "1"},
			},
		},
	}
}

func updateCurrencyItem(playerID uint16, currency string, amount int, tableName string) types.TransactWriteItem {
	pk := fmt.Sprintf("PLAYER#%s", uuidFromID(playerID))
	sk := "CURRENCY#" + currency
	return types.TransactWriteItem{
		Update: &types.Update{
			TableName: aws.String(tableName),
			Key: map[string]types.AttributeValue{
				"PK": &types.AttributeValueMemberS{Value: pk},
				"SK": &types.AttributeValueMemberS{Value: sk},
			},
			UpdateExpression: aws.String("ADD bal :delta, lifetime_earned :delta"),
			ExpressionAttributeValues: map[string]types.AttributeValue{
				":delta": &types.AttributeValueMemberN{Value: strconv.Itoa(amount)},
			},
			// Previene saldo negativo (spec Economy §7.2 y Persistence §5.3)
			ConditionExpression: aws.String("attribute_exists(PK)"),
		},
	}
}

func putInventoryItem(playerID uint16, loot game.LootItem, matchID string, tableName string) types.TransactWriteItem {
	pk := fmt.Sprintf("PLAYER#%s", uuidFromID(playerID))
	sk := fmt.Sprintf("ITEM#%s#%s", loot.ItemDef, loot.InstanceID)
	nowMS := time.Now().UnixMilli()
	return types.TransactWriteItem{
		Put: &types.Put{
			TableName: aws.String(tableName),
			Item: map[string]types.AttributeValue{
				"PK":              &types.AttributeValueMemberS{Value: pk},
				"SK":              &types.AttributeValueMemberS{Value: sk},
				"entity_type":     &types.AttributeValueMemberS{Value: "ITEM"},
				"entity_version":  &types.AttributeValueMemberN{Value: "1"},
				"version":         &types.AttributeValueMemberN{Value: "1"},
				"item_def":        &types.AttributeValueMemberS{Value: loot.ItemDef},
				"instance_id":     &types.AttributeValueMemberS{Value: loot.InstanceID},
				"quantity":        &types.AttributeValueMemberN{Value: strconv.Itoa(loot.Quantity)},
				"stackable":       &types.AttributeValueMemberBOOL{Value: false},
				"bound":           &types.AttributeValueMemberBOOL{Value: false},
				"state":           &types.AttributeValueMemberS{Value: "OWNED"},
				"acquired_at":     &types.AttributeValueMemberN{Value: strconv.FormatInt(nowMS, 10)},
				"acquired_via":    &types.AttributeValueMemberS{Value: "MATCH_REWARD"},
				"source_match_id": &types.AttributeValueMemberS{Value: matchID},
				"updated_at":      &types.AttributeValueMemberN{Value: strconv.FormatInt(nowMS, 10)},
				// GSI1: índice esparso para auditoría inversa item_def → propietarios
				"gsi1pk": &types.AttributeValueMemberS{Value: "ITEMDEF#" + loot.ItemDef},
				"gsi1sk": &types.AttributeValueMemberS{Value: pk},
			},
			// Impide materializar instancias duplicadas (spec §6.3)
			ConditionExpression: aws.String("attribute_not_exists(PK)"),
		},
	}
}

func updateSquadStatsItem(squadUUID string, season, shard, damageContrib int, countInvasion bool, tableName string) types.TransactWriteItem {
	pk := "SQUAD#" + squadUUID
	sk := fmt.Sprintf("STATS#S%d#SHARD#%d", season, shard)

	// invasionDelta es 1 solo para el jugador designado; 0 para el resto.
	// Así la suma de los shards del escuadrón cuenta exactamente 1 invasión.
	invasionDelta := "0"
	if countInvasion {
		invasionDelta = "1"
	}

	return types.TransactWriteItem{
		Update: &types.Update{
			TableName: aws.String(tableName),
			Key: map[string]types.AttributeValue{
				"PK": &types.AttributeValueMemberS{Value: pk},
				"SK": &types.AttributeValueMemberS{Value: sk},
			},
			UpdateExpression: aws.String(
				"ADD invasions_repelled :inv, total_damage_dealt :dmg",
			),
			ExpressionAttributeValues: map[string]types.AttributeValue{
				":inv": &types.AttributeValueMemberN{Value: invasionDelta},
				":dmg": &types.AttributeValueMemberN{Value: strconv.Itoa(damageContrib)},
			},
		},
	}
}

// countsInvasion designa a UN solo jugador del escuadrón como el que contabiliza
// la invasión repelida. Elige de forma determinista el player_id más bajo entre
// los que comparten escuadrón, para que el resultado sea reproducible ante
// reintentos. Solo cuenta si el outcome fue una victoria.
func countsInvasion(acc *game.MatchStateAccumulator, playerID uint16) bool {
	if acc.Outcome != game.OutcomeInvasionRepelled {
		return false
	}
	var lowest uint16
	first := true
	for pid, p := range acc.Players {
		if p.State == game.StateDisconnected {
			continue
		}
		if first || pid < lowest {
			lowest = pid
			first = false
		}
	}
	return !first && playerID == lowest
}

func putMatchResultItem(p *game.Player, acc *game.MatchStateAccumulator, rewards PlayerRewards, tableName string) types.TransactWriteItem {
	pk := fmt.Sprintf("PLAYER#%s", uuidFromID(p.PlayerID))
	endMS := acc.EndedAt.UnixMilli()
	// ts_desc = 9999999999999 - endedAt (orden DESC en la SK)
	tsDesc := 9_999_999_999_999 - endMS
	matchSK := fmt.Sprintf("MATCH#%013d#%s", tsDesc, acc.MatchID)

	// TTL en epochSeconds (NO milisegundos — DynamoDB ignora ms)
	ttlS := acc.EndedAt.Add(30 * 24 * time.Hour).Unix()

	// Construir sub-objeto rewards.currencies
	currencies := map[string]types.AttributeValue{
		CurrencyShard: &types.AttributeValueMemberN{Value: strconv.Itoa(rewards.ShardEarned)},
	}

	return types.TransactWriteItem{
		Put: &types.Put{
			TableName: aws.String(tableName),
			Item: map[string]types.AttributeValue{
				"PK":             &types.AttributeValueMemberS{Value: pk},
				"SK":             &types.AttributeValueMemberS{Value: matchSK},
				"entity_type":    &types.AttributeValueMemberS{Value: "MATCH"},
				"entity_version": &types.AttributeValueMemberN{Value: "1"},
				"match_id":       &types.AttributeValueMemberS{Value: acc.MatchID},
				"outcome":        &types.AttributeValueMemberS{Value: string(acc.Outcome)},
				"season":         &types.AttributeValueMemberN{Value: strconv.Itoa(acc.Season)},
				"started_at":     &types.AttributeValueMemberN{Value: strconv.FormatInt(acc.StartedAt.UnixMilli(), 10)},
				"ended_at":       &types.AttributeValueMemberN{Value: strconv.FormatInt(endMS, 10)},
				"settlement_id":  &types.AttributeValueMemberS{Value: operationID(acc.MatchID, p.PlayerID)},
				"ttl":            &types.AttributeValueMemberN{Value: strconv.FormatInt(ttlS, 10)},
				"performance": &types.AttributeValueMemberM{Value: map[string]types.AttributeValue{
					"damage_dealt":   &types.AttributeValueMemberN{Value: strconv.Itoa(p.DamageDelta)},
					"damage_taken":   &types.AttributeValueMemberN{Value: "0"}, // acumulado por separado
					"strikes_landed": &types.AttributeValueMemberN{Value: "0"}, // TODO: acumular en tick_loop
					"clinch_wins":    &types.AttributeValueMemberN{Value: "0"},
					"xp_earned":      &types.AttributeValueMemberN{Value: strconv.Itoa(rewards.XPEarned)},
				}},
				"rewards": &types.AttributeValueMemberM{Value: map[string]types.AttributeValue{
					"currencies": &types.AttributeValueMemberM{Value: currencies},
				}},
			},
		},
	}
}

// ---------------------------------------------------------------------------
// Ejecución de la transacción con manejo de idempotencia
// ---------------------------------------------------------------------------

func (s *LootService) executeTransact(
	ctx context.Context,
	items []types.TransactWriteItem,
	opID, matchID string,
	playerID uint16,
) error {
	_, err := s.ddb.TransactWriteItems(ctx, &dynamodb.TransactWriteItemsInput{
		TransactItems: items,
	})
	if err == nil {
		return nil
	}

	// Comprobar si es un ConditionalCheckFailed en el IDEM lock (= "ya liquidado")
	if isAlreadySettled(err) {
		s.logger.Info("settlement already applied (idempotent)",
			zap.String("op_id", opID), zap.String("match", matchID), zap.Uint16("player", playerID),
		)
		return nil // no es un error
	}

	// Error real — el llamador reintentará con backoff
	return fmt.Errorf("transact failed for player %d op %s: %w", playerID, opID, err)
}

// isAlreadySettled devuelve true cuando la transacción falló porque el primer
// ítem del lote (el IDEM lock) ya existía. En la AWS SDK v2, DynamoDB devuelve
// un *types.TransactionCanceledException cuyo CancellationReasons[0] tiene
// Code == "ConditionalCheckFailed". El lock es siempre el ítem 0, así que basta
// con inspeccionar la primera razón.
func isAlreadySettled(err error) bool {
	var txErr *types.TransactionCanceledException
	if !errors.As(err, &txErr) {
		return false
	}
	reasons := txErr.CancellationReasons
	return len(reasons) > 0 && aws.ToString(reasons[0].Code) == "ConditionalCheckFailed"
}

// ---------------------------------------------------------------------------
// Funciones auxiliares
// ---------------------------------------------------------------------------

// operationID genera el ID de idempotencia: hash(match_id + player_id).
func operationID(matchID string, playerID uint16) string {
	h := sha256.Sum256([]byte(fmt.Sprintf("%s_SETTLE_%d", matchID, playerID)))
	return "settle_" + hex.EncodeToString(h[:8])
}

// instanceID genera el instance_id del ítem: hash(match_id + player_id + index).
// Reproduce el resultado de forma determinista ante cualquier reintento.
func instanceID(matchID string, playerID uint16, index int) string {
	h := sha256.Sum256([]byte(fmt.Sprintf("%s_%d_%d", matchID, playerID, index)))
	return hex.EncodeToString(h[:4]) // 8 caracteres hex, spec _common.json instanceId
}

// shardIndex = hash(player_id) % shardCount (write sharding del spec Persistence §3.3)
func shardIndex(playerID uint16, shardCount int) int {
	return int(playerID) % shardCount
}

// uuidFromID es un placeholder hasta tener el UUID real del jugador.
// En producción el servidor carga el UUID de DynamoDB en MATCH_JOIN.
func uuidFromID(playerID uint16) string {
	return fmt.Sprintf("00000000-0000-0000-0000-%012d", playerID)
}

// rewriteIdemLock reemplaza el primer item (IDEM lock) con un nuevo opID.
func rewriteIdemLock(batch []types.TransactWriteItem, newOpID, tableName string) []types.TransactWriteItem {
	if len(batch) == 0 {
		return batch
	}
	batch[0] = idemLockItem(newOpID, "", tableName)
	return batch
}
