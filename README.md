# PixelRift / kiro_world

Base técnica de una aplicación Android de combate táctico en Realidad Aumentada,
desarrollada con enfoque **Spec-Driven Development (SDD)**: cada módulo tiene
primero su especificación técnica y luego su implementación verificada.

## Especificaciones técnicas

| Documento | Módulo |
|-----------|--------|
| `TECHNICAL_SPEC.md` | Motor de renderizado 2.5D Anime Pixel Art (ARCore + Godot + Edge AI) |
| `MULTIPLAYER_TECHNICAL_SPEC.md` | Sincronización multijugador (Cloud Anchors, UDP autoritativo, Kubernetes/Agones) |
| `PERSISTENCE_TECHNICAL_SPEC.md` | Persistencia y progresión (DynamoDB single-table, pipeline Lakehouse) |
| `GAMELOOP_TECHNICAL_SPEC.md` | Core Game Loop (FSM del jugador, mecánicas AR por clase, economía dual) |

## Estructura del proyecto

```
kiro-fig/
├── core/ · render/ · data/ · inference/    Cliente AR de renderizado (Godot + GLSL)
├── analytics/ · utils/                      Monitoreo térmico y gestión de memoria
├── android/                                 Configuración de build Android
│
├── persistence/
│   ├── schemas/                             Esquemas JSON de las entidades DynamoDB
│   └── terraform/                           IaC: tabla, GSI, pipeline CDC, IAM
│
└── game_loop/
    ├── client/                              Cliente del Game Loop (GDScript)
    │   ├── states/                          FSM del jugador
    │   ├── network/                         UDP, ActionIntent, interpolación
    │   └── classes/                         Controladores Guerrero / Mago / Healer
    └── server/                              Servidor autoritativo headless (Go)
        ├── cmd/gameserver/                  Entry point + listener UDP
        └── pkg/                             game · spatial · economy
```

## Verificación

- **Backend Go** (`game_loop/server`): `go build ./...`, `go vet ./...` y `gofmt` limpios (Go 1.27).
- **Cliente Godot** (`game_loop/client`): los 7 scripts pasan `--check-only` en Godot 4.7.

## Estado

Fase de especificación e implementación base. La validación en runtime (servidor
UDP en vivo, dispositivo AR, despliegue en Kubernetes) queda fuera del alcance actual.
