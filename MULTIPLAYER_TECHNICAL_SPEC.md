# TECHNICAL SPEC - Multijugador PixelRift
## Sincronización Espacial con Cloud Anchors y Backend UDP Autoritativo

---

## 1. Visión del Módulo

Sistema multijugador para sincronizar múltiples jugadores en el mismo entorno físico utilizando un **origen espacial compartido**, respaldado por un **backend autoritativo de baja latencia** que gestiona el estado del combate táctico.

### Stack Tecnológico

| Componente | Tecnología | Motivación |
|------------|------------|------------|
| Capa Espacial | Google ARCore (Cloud Anchors API) | Compartición de coordenadas físicas globales |
| Cliente | Godot Engine (C++ / GDScript) | Renderizado 2.5D, orquestación de nodos |
| Backend | Servidor Headless (Go/C++) | Lógica autoritativa, estado del juego |
| Transporte | UDP unicast/multicast | Latencia mínima, tick rate 30 Hz |
| Orquestación | Kubernetes + Agones | Scaling automático de contenedores |
| IaC | Terraform | Infraestructura reproducible |

---

## 2. Diagrama de Secuencia: Ciclo de Vida del CloudAnchorID

```
┌─────────────┐     ┌──────────────┐     ┌──────────────┐     ┌─────────────┐
│   Host      │     │  Backend     │     │  Cloud API   │     │   Client    │
│  Player A   │     │  Game Server │     │  (Google)    │     │  Player B   │
└──────┬──────┘     └──────┬───────┘     └──────┬───────┘     └──────┬──────┘
       │                   │                      │                   │
       │ 1. Create Anchor  │                      │                   │
       │──────────────────>│                      │                   │
       │                   │                      │                   │
       │ 2. CloudAnchorID  │                      │                   │
       │<──────────────────│                      │                   │
       │                   │                      │                   │
       │                   │ 3. Store Anchor      │                   │
       │                   │─────────────────────>│                   │
       │                   │                      │                   │
       │                   │ 4. Ack               │                   │
       │                   │<─────────────────────│                   │
       │                   │                      │                   │
       │                   │ 5. Broadcast ID      │                   │
       │                   │─────────────────────────────────────────>│
       │                   │                      │                   │
       │                   │                      │ 6. Resolve Anchor │
       │                   │                      │──────────────────>│
       │                   │                      │                   │
       │                   │                      │ 7. Local Offset   │
       │                   │                      │<──────────────────│
       │                   │                      │                   │
       │                   │                      │ 8. Sync Position  │
       │                   │                      │──────────────────>│
       │                   │                      │                   │
       │                   │                      │ 9. Game State     │
       │                   │                      │<──────────────────│
```

### Estados del Ciclo

| Paso | Evento | Latencia Objetivo | Timeout |
|------|--------|-------------------|---------|
| 1-2 | Create & Return ID | < 200 ms | 5 s |
| 3-4 | Store in Backend | < 50 ms | 2 s |
| 5-6 | Broadcast & Resolve | < 1 s | 5 s (reintentar) |
| 7-9 | Sync & Game Start | < 50 ms | N/A |

---

## 3. Topología del Árbol de Nodos (Godot)

### Estructura de Jerarquía

```
WorldRoot (Spatial)
├── CloudAnchorNode (Spatial)  ← Punto de sincronización espacial
│   ├── PlayerLocal (Spatial)
│   │   ├── Camera3D
│   │   └── HandModels
│   │
│   ├── RemotePlayersGroup (Node)
│   │   ├── RemotePlayer_1 (Spatial)
│   │   │   ├── Model3D
│   │   │   └── NetworkState
│   │   ├── RemotePlayer_2 (Spatial)
│   │   │   ├── Model3D
│   │   │   └── NetworkState
│   │   └── RemotePlayer_N (Spatial)
│   │       ├── Model3D
│   │       └── NetworkState
│   │
│   └── EntitiesGroup (Node)
│       ├── EnemyBot_1 (Spatial)
│       ├── EnemyBot_2 (Spatial)
│       └── EnvironmentObstacles (Spatial)
│
└── Environment (Node3D)
    ├── Terrain
    ├── StaticObstacles
    └── PhysicsWorld
```

### Mecanismo de Emparentamiento

```gdscript
# Core: world_manager.gd - Sync Spatial

func _on_cloud_anchor_resolved(anchor_id: String, transform: Transform):
    # 1. Locate CloudAnchorNode en el mundo
    var anchor_node = world_root.get_node("CloudAnchorNode")
    
    # 2. Aplicar transformación desde coordenadas locales a físicas
    # transform = Pose global del anchor (mundo físico real)
    anchor_node.global_transform = transform
    
    # 3. Reparentizar entidades remotas dinámicamente
    for remote_player in remote_players_group.get_children():
        remote_player.reparent(anchor_node, true)
    
    # 4. Sincronizar estado inicial
    sync_initial_state(anchor_node)
    
    print("[WorldManager] Cloud Anchor resuelto. Transform: %s" % transform)
```

### Protocolo de Reparentizado

1. **Resolución del Anchor:** El cliente obtiene el `Transform` global desde el backend
2. **Reparentizado:** Todas las entidades remotas se emparentan bajo `CloudAnchorNode`
3. **Sincronización:** El servidor envía la posición relativa al anchor (no global)
4. **Renderizado:** Godot aplica el `global_transform` para proyectar en el mundo físico

---

## 4. Contrato de Datos de Red (UDP Payload)

### 4.1. Esquema Binario Comprimido (< 512 bytes)

```
┌────────────────────────────────────────────────────────────────────┐
│                         UDP PACKET FORMAT                          │
├────────────────────────────────────────────────────────────────────┤
│ Byte 0-1  : PacketID (uint16_le)       Identificador de secuencia │
│ Byte 2    : PacketType (uint8)         0x01=Update, 0x02=SyncReq  │
│ Byte 3    : PlayerCount (uint8)        Jugadores en partida       │
│                                                                    │
│ Byte 4-5  : Timestamp (uint16_le)      Tick actual (30 Hz)        │
│ Byte 6-9  : Checksum (uint32_le)       CRC32 de validación        │
│                                                                    │
│ [PAYLOAD - Variable Length]                                        │
│                                                                    │
│ Para cada jugador (20 bytes por jugador):                         │
│   Byte 0-1  : PlayerID (uint16_le)                                 │
│   Byte 2-3  : Flags (uint16_le)      [0:Alive, 1:Striking, 2:Clinch]│
│   Byte 4-5  : Health (uint16_le)     [0-100]                      │
│   Byte 6-9  : PositionX (int32_le)   [cm, -32768 a 32767]        │
│   Byte 10-13: PositionY (int32_le)   [cm, -32768 a 32767]        │
│   Byte 14-17: PositionZ (int32_le)   [cm, -32768 a 32767]        │
│   Byte 18-19: Rotation (uint16_le)   [0-359 grados, q15 format]  │
│                                                                    │
│ Para cada entidad (16 bytes por entidad):                         │
│   Byte 0-1  : EntityID (uint16_le)                                 │
│   Byte 2-5  : PositionX (int32_le)   [cm]                         │
│   Byte 6-9  : PositionY (int32_le)   [cm]                         │
│   Byte 10-13: PositionZ (int32_le)   [cm]                         │
│   Byte 14-15: EntityType (uint16_le) [0=Enemy, 1=Item, 2=Prop]   │
└────────────────────────────────────────────────────────────────────┘
```

### 4.2. Esquema JSON (Debug / Logging)

```json
{
  "packet_id": 12345,
  "packet_type": "UPDATE",
  "timestamp": 45678,
  "checksum": "a1b2c3d4",
  "players": [
    {
      "player_id": 1,
      "flags": ["ALIVE", "STRIKING"],
      "health": 85,
      "position": {"x": 123, "y": 0, "z": -456},
      "rotation": 135
    },
    {
      "player_id": 2,
      "flags": ["ALIVE"],
      "health": 42,
      "position": {"x": -78, "y": 12, "z": 234},
      "rotation": 270
    }
  ],
  "entities": [
    {
      "entity_id": 101,
      "position": {"x": 500, "y": 0, "z": 300},
      "entity_type": "ENEMY"
    }
  ]
}
```

### 4.3. Compresión y Optimización

| Técnica | Aplicación | Reducción |
|---------|----------|-----------|
| **Int32 → Int16** | Coordenadas en cm (rango ±327m) | 50% |
| **Flags compactos** | 3 estados en 1 bit cada uno | 87.5% |
| **Delta encoding** | Solo enviar cambios > 5 cm | 40% |
| **Zlib (opcional)** | Paquetes > 256 bytes | 20-30% |

**Payload Target: ~200-350 bytes** (margen de 162-312 bytes)

### 4.4. Tipos de Paquetes

| Type | Opcode | Descripción | Tamaño |
|------|--------|-------------|--------|
| UPDATE | 0x01 | Estado del juego | 20 + (20 × N_players) + (16 × N_entities) |
| SYNC_REQ | 0x02 | Solicitar estado inicial | 8 bytes |
| SYNC_RESP | 0x03 | Respuesta de estado inicial | Variable |
| HEARTBEAT | 0x04 | Keep-alive | 8 bytes |

---

## 5. Escalabilidad y FinOps: Kubernetes + Agones

### 5.1. Arquitectura de Infraestructura

```
┌────────────────────────────────────────────────────────────────────────────┐
│                         CLOUD INFRASTRUCTURE                               │
├────────────────────────────────────────────────────────────────────────────┤
│                                                                            │
│  ┌────────────────────────────────────────────────────────────────────┐   │
│  │                        GKE Cluster                                  │   │
│  │  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐     │   │
│  │  │  Master Node    │  │  Worker Pool A  │  │  Worker Pool B  │     │   │
│  │  │  (Control Plane)│  │  (Game Servers) │  │  (Auto-scaling) │     │   │
│  │  └─────────────────┘  └─────────────────┘  └─────────────────┘     │   │
│  │                            │                        │              │   │
│  │                            ▼                        ▼              │   │
│  │                    ┌──────────────┐        ┌──────────────┐        │   │
│  │                    │ Agones Hub   │        │ HPA Metrics  │        │   │
│  │                    │ (GameServer) │        │ (CPU/Conn)   │        │   │
│  │                    └──────┬───────┘        └──────┬───────┘        │   │
│  │                           │                       │                │   │
│  │                           ▼                       ▼                │   │
│  │                   ┌─────────────┐         ┌─────────────┐          │   │
│  │                   │ GameServer  │         │  Scale Up   │          │   │
│  │                   │ Pod A       │         │  New Pod    │          │   │
│  │                   │ UDP:30000   │         │  UDP:30001  │          │   │
│  │                   └─────────────┘         └─────────────┘          │   │
│  │                                                                      │   │
│  └────────────────────────────────────────────────────────────────────┘   │
│                                                                            │
└────────────────────────────────────────────────────────────────────────────┘
```

### 5.2. Configuración Terraform (Node Pools)

```hcl
# terraform/modules/gke-cluster/main.tf

resource "google_container_cluster" "game_servers" {
  name     = "pixelft-udp-cluster"
  location = var.region

  # Master configuration
  master_auth {
    client_certificate_config {
      issue_client_certificate = false
    }
  }

  # Network policy
  network_policy {
    enabled = true
    provider = "CALICO"
  }

  # Node pools
  node_pool {
    name       = "game-servers"
    node_count = 2

    node_config {
      machine_type = "e2-standard-4"
      disk_size_gb = 100
      preemptible  = false
      
      # Labels for Agones
      labels = {
        role = "game-server"
        tier = "udp"
      }
      
      # Taints to prevent non-game workloads
      taint {
        key    = "dedicated"
        value  = "game-servers"
        effect = "PREFER_NO_SCHEDULE"
      }
    }

    management {
      auto_repair  = true
      auto_upgrade = true
    }
  }

  # Auto-scaling pool for burst
  node_pool {
    name       = "auto-scaler"
    node_count = 0
    max_nodes  = 10
    min_nodes  = 0

    node_config {
      machine_type = "e2-small"
      disk_size_gb = 50
      preemptible  = true
      
      labels = {
        role = "autoscaler"
      }
    }

    management {
      auto_repair  = true
      auto_upgrade = true
    }
  }
}

# Agones Operator Installation
resource "kubernetes_namespace" "agones" {
  metadata {
    name = "agones-system"
  }
}

resource "helm_release" "agones" {
  name       = "agones"
  repository = "https://charts.agones.io"
  chart      = "agones"
  namespace  = kubernetes_namespace.agones.metadata[0].name

  set {
    name  = "sdk.server.serviceType"
    value = "NodePort"
  }
}
```

### 5.3. Horizontal Pod Autoscaler (HPA)

```yaml
# k8s/hpa-game-server.yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: game-server-hpa
  namespace: default
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind:       Deployment
    name:       game-server-deployment
  minReplicas: 2
  maxReplicas: 20
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
  - type: Resource
    resource:
      name: connections
      target:
        type: AverageValue
        averageValue: "50"  # 50 jugadores por servidor
```

### 5.4. GameServer Allocation (Agones)

```yaml
# k8s/gameserver.yaml
apiVersion: "agones.dev/v1"
kind: GameServer
metadata:
  name: pixelft-udp-server
  labels:
    app: pixelft-udp
spec:
  template:
    spec:
      containers:
      - name: server
        image: gcr.io/pixelft/game-server:v1.0.0
        ports:
        - containerPort: 30000
          protocol: UDP
        resources:
          requests:
            memory: "512Mi"
            cpu: "500m"
          limits:
            memory: "1Gi"
            cpu: "1"
        env:
        - name: PORT
          value: "30000"
        - name: MODE
          value: "UDP"
        - name: MAX_PLAYERS
          value: "50"
```

---

## 6. Criterios de Aceptación Técnicos (SLAs de Red e Infraestructura)

| SLA | Requerimiento | Mecanismo de Validación |
|-----|---------------|------------------------|
| **Tick Rate** | 30 ticks/segundo | Timer en servidor, promedio 1s |
| **Payload Size** | < 512 bytes/paquete | Wireshark/tcpdump |
| **UDP Latency** | < 50 ms (p95) | netperf, ping |
| **Cloud Anchor Timeout** | < 5 s (reintentar) | Timeout handler, backoff |
| **Auto-scaling** | Scale to 0 in off-peak | Terraform FinOps metrics |
| **Concurrent Players/Server** | 50 jugadores máx. | Load test (Locust) |
| **Packet Loss** | < 1% (UDP) | Flow statistics |
| **Recovery Time** | < 10 s (failover) | Chaos engineering |

---

## 7. Plan de Implementación

### Fase 1: Arquitectura Base (Aprobación requerida)
1. Implementar bridge UDP en Godot (C++/GDNative)
2. Integrar Cloud Anchors API (Android native)
3. Crear esquema binario de paquetes

### Fase 2: Backend Autoritativo
1. Desarrollar servidor Go (UDP listener)
2. Implementar estado del juego (tick rate 30 Hz)
3. Integrar con Cloud Anchors API

### Fase 3: Orquestación Kubernetes
1. Terraform: Crear cluster GKE
2. Install Agones operator
3. Configurar HPA y GameServer

### Fase 4: Test de Escalabilidad
1. Load test (Locust)
2. Chaos engineering (Simian Army)
3. FinOps analysis

---

## 8. Referencias Técnicas

- [ARCore Cloud Anchors Documentation](https://developers.google.com/ar/develop/cloud-anchors)
- [Agones Documentation](https://agones.dev/site/docs/)
- [UDP Best Practices](https://learn.unity.com/tutorial/introduction-to-multiplayer-and-networking)
- [Google Kubernetes Engine](https://cloud.google.com/kubernetes-engine)

---

**Documento elaborado por:** Arquitecto de Redes Senior y Cloud DevOps Engineer  
**Versión:** 1.0  
**Fecha:** 31 Agosto 2026  
**Estado:** Pendiente de aprobación de arquitectura de red
