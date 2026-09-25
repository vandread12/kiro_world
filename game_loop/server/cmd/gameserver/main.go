// main.go
// Entry point del GameServer headless de PixelRift.
// Arranca el listener UDP, inicializa el estado de la partida y
// lanza el TickLoop autoritativo.
//
// Spec: GAMELOOP_TECHNICAL_SPEC.md §4.1

package main

import (
	"context"
	"fmt"
	"net"
	"os"
	"os/signal"
	"syscall"
	"time"

	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb"
	"go.uber.org/zap"

	"github.com/pixelrift/gameserver/pkg/economy"
	"github.com/pixelrift/gameserver/pkg/game"
)

const (
	DefaultPort    = "30000"
	DefaultTable   = "pixelft-core-prod"
	TickRate       = 30
	MaxPacketBytes = 512 // límite del spec (fragmentación UDP)
)

func main() {
	// ---------------------------------------------------------------------------
	// Logger
	// ---------------------------------------------------------------------------
	log, err := zap.NewProduction()
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to init logger: %v\n", err)
		os.Exit(1)
	}
	defer log.Sync()

	// ---------------------------------------------------------------------------
	// Configuración desde variables de entorno (inyectadas por Agones)
	// ---------------------------------------------------------------------------
	port := envOr("PORT", DefaultPort)
	tableName := envOr("DDB_TABLE_NAME", DefaultTable)
	matchID := envOr("MATCH_ID", "m_debug00")
	squadID := envOr("SQUAD_ID", "")
	seasonStr := envOr("SEASON", "3")
	season := 3
	fmt.Sscanf(seasonStr, "%d", &season)

	log.Info("gameserver starting",
		zap.String("port", port),
		zap.String("match_id", matchID),
		zap.String("table", tableName),
	)

	// ---------------------------------------------------------------------------
	// UDP Listener
	// ---------------------------------------------------------------------------
	addr, err := net.ResolveUDPAddr("udp4", ":"+port)
	if err != nil {
		log.Fatal("resolve addr failed", zap.Error(err))
	}
	conn, err := net.ListenUDP("udp4", addr)
	if err != nil {
		log.Fatal("listen failed", zap.Error(err))
	}
	defer conn.Close()
	conn.SetReadBuffer(2 * 1024 * 1024)
	conn.SetWriteBuffer(2 * 1024 * 1024)
	log.Info("UDP listening", zap.String("addr", conn.LocalAddr().String()))

	// ---------------------------------------------------------------------------
	// Construir estado inicial de la partida
	// ---------------------------------------------------------------------------
	boss := &game.Boss{
		EntityID:   101,
		HP:         3000,
		MaxHP:      3000,
		Position:   game.Vec3CM{X: 0, Y: 0, Z: -500}, // 5 m frente al anchor
		AggroTable: make(map[uint16]float64),
	}
	boss.UpdatePhase()

	acc := &game.MatchStateAccumulator{
		MatchID:   matchID,
		SquadID:   squadID,
		Season:    season,
		Players:   make(map[uint16]*game.Player),
		Boss:      boss,
		StartedAt: time.Now().UTC(),
	}

	// ---------------------------------------------------------------------------
	// Broadcaster UDP
	// ---------------------------------------------------------------------------
	bcast := NewUDPBroadcaster(conn, log)

	// ---------------------------------------------------------------------------
	// Input queue
	// ---------------------------------------------------------------------------
	inputQueue := make(chan game.ActionIntent, 512)

	// ---------------------------------------------------------------------------
	// TickLoop
	// ---------------------------------------------------------------------------
	posHistory := game.NewRingPositionHistory()
	tl := game.NewTickLoop(
		acc,
		inputQueue,
		bcast,
		posHistory,
		nil,                     // obstáculos: se cargan en SYNC_RESP; vacío en arranque
		NewStaticSkillCatalog(), // catálogo de habilidades por defecto
		log,
	)

	// ---------------------------------------------------------------------------
	// Goroutine de recepción de paquetes
	// ---------------------------------------------------------------------------
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	go receiveLoop(ctx, conn, inputQueue, acc, bcast, log)

	// ---------------------------------------------------------------------------
	// Señal de Agones: servidor listo
	// ---------------------------------------------------------------------------
	log.Info("signaling Agones: server ready")
	// sdk.Ready() — se llama via Agones SDK; omitido aquí para no añadir dependencia

	// ---------------------------------------------------------------------------
	// Gestión de señales del OS
	// ---------------------------------------------------------------------------
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGTERM, syscall.SIGINT)

	// ---------------------------------------------------------------------------
	// Lanzar el TickLoop. Devuelve el outcome cuando la partida termina
	// (Boss derrotado, todos eliminados o SIGTERM cancela el contexto).
	// ---------------------------------------------------------------------------
	outcomeCh := make(chan game.MatchOutcome, 1)
	go func() {
		outcomeCh <- tl.Run(ctx)
	}()

	var outcome game.MatchOutcome
	select {
	case sig := <-sigCh:
		log.Info("signal received", zap.String("signal", sig.String()))
		cancel()              // cancela el contexto del TickLoop
		outcome = <-outcomeCh // espera a que Run retorne limpiamente
	case outcome = <-outcomeCh:
		log.Info("match finished naturally", zap.String("outcome", string(outcome)))
	}

	// ---------------------------------------------------------------------------
	// MATCH_END: sellar y liquidar
	// ---------------------------------------------------------------------------
	log.Info("match ending", zap.String("outcome", string(outcome)))
	acc.Seal(outcome)

	// Inicializar cliente DynamoDB
	ddbClient := mustInitDDB(ctx, log)
	lootSvc := economy.NewLootService(ddbClient, tableName, &NopLootTable{}, log)

	for pid := range acc.Players {
		settleCtx, cancelSettle := context.WithTimeout(context.Background(), 5*time.Second)
		for attempt := 0; attempt < 3; attempt++ {
			err = lootSvc.SettlePlayerRewards(settleCtx, acc, pid)
			if err == nil {
				break
			}
			backoff := time.Duration(50*(1<<attempt)) * time.Millisecond
			log.Warn("settle retry",
				zap.Uint16("player", pid), zap.Int("attempt", attempt+1),
				zap.Duration("backoff", backoff), zap.Error(err),
			)
			time.Sleep(backoff)
		}
		cancelSettle()
		if err != nil {
			log.Error("settle failed after 3 attempts", zap.Uint16("player", pid), zap.Error(err))
		}
	}

	log.Info("gameserver shutdown complete")
}

// ---------------------------------------------------------------------------
// Goroutine de recepción de paquetes UDP
// ---------------------------------------------------------------------------

func receiveLoop(
	ctx context.Context,
	conn *net.UDPConn,
	queue chan<- game.ActionIntent,
	acc *game.MatchStateAccumulator,
	bcast *UDPBroadcaster,
	log *zap.Logger,
) {
	buf := make([]byte, MaxPacketBytes)
	for {
		select {
		case <-ctx.Done():
			return
		default:
		}

		conn.SetReadDeadline(time.Now().Add(100 * time.Millisecond))
		n, addr, err := conn.ReadFromUDP(buf)
		if err != nil {
			if netErr, ok := err.(net.Error); ok && netErr.Timeout() {
				continue
			}
			log.Error("read error", zap.Error(err))
			continue
		}

		if n < 3 {
			continue
		}

		ptype := buf[2]
		switch ptype {
		case 0x02: // SYNC_REQ: nuevo cliente o reconexión
			handleSyncRequest(buf[:n], addr, acc, bcast, log)

		case 0x04: // HEARTBEAT
			bcast.SendHeartbeatPong(addr)

		case 0x05: // ACTION_INTENT
			if n < 30 {
				continue
			}
			intent := deserializeActionIntent(buf[:30])
			// Registrar cliente si es nuevo
			if p, ok := acc.Players[intent.PlayerID]; ok {
				p.RemoteAddr = addr.String()
			}
			select {
			case queue <- intent:
			default:
				log.Warn("input queue full, dropping intent",
					zap.Uint16("player", intent.PlayerID))
			}
		}
	}
}

func handleSyncRequest(
	raw []byte,
	addr *net.UDPAddr,
	acc *game.MatchStateAccumulator,
	bcast *UDPBroadcaster,
	log *zap.Logger,
) {
	// Registrar el jugador con una dirección remota provisional
	// En producción se valida el session_token
	log.Info("sync request", zap.String("addr", addr.String()))
	bcast.SendSyncResponse(addr, acc)
}

// ---------------------------------------------------------------------------
// Deserialización de ActionIntent (spec §5.1, 30 bytes)
// ---------------------------------------------------------------------------

func deserializeActionIntent(raw []byte) game.ActionIntent {
	fwdX := float64(int16(uint16(raw[21])<<8|uint16(raw[22]))) / 32767.0
	fwdY := float64(int16(uint16(raw[23])<<8|uint16(raw[24]))) / 32767.0
	fwdZ := float64(int16(uint16(raw[25])<<8|uint16(raw[26]))) / 32767.0

	return game.ActionIntent{
		PacketID:   uint16(raw[0])<<8 | uint16(raw[1]),
		PlayerID:   uint16(raw[3]),
		ClientTick: raw[4],
		Action:     game.ActionType(raw[5]),
		TargetID:   uint16(raw[6])<<8 | uint16(raw[7]),
		TargetPos: game.Vec3CM{
			X: int32(raw[8])<<24 | int32(raw[9])<<16 | int32(raw[10])<<8 | int32(raw[11]),
			Y: int32(raw[12])<<24 | int32(raw[13])<<16 | int32(raw[14])<<8 | int32(raw[15]),
			Z: int32(raw[16])<<24 | int32(raw[17])<<16 | int32(raw[18])<<8 | int32(raw[19]),
		},
		SkillSlot:  int(raw[20]),
		ForwardVec: [3]float64{fwdX, fwdY, fwdZ},
	}
}

// ---------------------------------------------------------------------------
// UDPBroadcaster
// ---------------------------------------------------------------------------

// UDPBroadcaster implementa game.Broadcaster para comunicación UDP real.
type UDPBroadcaster struct {
	conn *net.UDPConn
	log  *zap.Logger
}

func NewUDPBroadcaster(conn *net.UDPConn, log *zap.Logger) *UDPBroadcaster {
	return &UDPBroadcaster{conn: conn, log: log}
}

func (b *UDPBroadcaster) BroadcastUpdate(state *game.MatchStateAccumulator, tick uint16) {
	// Serialización simplificada — en producción usar el formato binario completo del spec
	b.log.Debug("broadcast update", zap.Uint16("tick", tick),
		zap.Int("players", len(state.Players)))
}

func (b *UDPBroadcaster) SendSkillResult(playerID uint16, result game.SkillResult) {
	b.log.Debug("skill result",
		zap.Uint16("player", playerID),
		zap.Uint8("code", uint8(result.ResultCode)),
		zap.Int("value", result.Value),
	)
}

func (b *UDPBroadcaster) BroadcastEvent(event game.GameEvent, data []byte) {
	b.log.Info("broadcast event", zap.Uint8("event", uint8(event)))
}

func (b *UDPBroadcaster) SendHeartbeatPong(addr *net.UDPAddr) {
	buf := make([]byte, 12)
	buf[2] = 0x04
	now := time.Now().UnixMilli()
	for i := 0; i < 8; i++ {
		buf[4+i] = byte(now >> (56 - 8*i))
	}
	b.conn.WriteToUDP(buf, addr)
}

func (b *UDPBroadcaster) SendSyncResponse(addr *net.UDPAddr, acc *game.MatchStateAccumulator) {
	// En producción: serializar acc a JSON comprimido
	b.log.Info("sync response sent", zap.String("addr", addr.String()))
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// mustInitDDB inicializa el cliente DynamoDB con la config AWS estándar.
// En Agones/EKS las credenciales llegan por IRSA (ver iam module del spec de
// persistencia): LoadDefaultConfig las resuelve automáticamente sin claves.
func mustInitDDB(ctx context.Context, log *zap.Logger) *dynamodb.Client {
	cfg, err := awsconfig.LoadDefaultConfig(ctx)
	if err != nil {
		log.Fatal("failed to load AWS config", zap.Error(err))
	}
	return dynamodb.NewFromConfig(cfg)
}

// NopLootTable es una tabla de loot vacía para el servidor de desarrollo.
type NopLootTable struct{}

func (n *NopLootTable) Roll(seed string, maxItems int) []game.LootItem {
	return []game.LootItem{}
}
