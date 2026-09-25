# TECHNICAL SPEC - Android ARCore + Godot 2.5D Anime Pixel Art Engine
## Arquitectura de Renderizado con Edge AI en Dispositivos Móviles

---

## 1. Visión del Proyecto

Aplicación Android que ingesta datos espaciales del entorno físico en tiempo real y los renderiza como un escenario tridimensional interactivo con estética **2.5D Anime Pixel Art**.

### Stack Tecnológico

| Componente | Tecnología | Motivación |
|------------|------------|------------|
| Motor Base | Godot Engine 4.x (C++ / GDScript) | Optimizado para Android, licencia MIT, renderizado personalizable |
| Ingesta Espacial | Google ARCore (Depth API + Scene Semantics) | Provee tensor de profundidad y segmentación semántica |
| Inferencia | TensorFlow Lite + NNAPI | Delegación a NPU/GPU, bajo consumo, sin bloqueo de main thread |
| Renderizado | GLSL Fragment/Vertex Shaders | Procesamiento directo en GPU, latencia de milisegundos |

---

## 2. Diagrama de Flujo del Pipeline de Datos

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                                 SENSOR FUSION LAYER                                     │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐               │
│  │   ARCore     │  │   ARCore     │  │   ARCore     │  │   Sensor     │               │
│  │   Camera     │  │    Depth     │  │   Semantics  │  │    Fusion    │               │
│  │   (RGB)      │  │    Map       │  │   (Labels)   │  │   (Gyroscope│               │
│  │  1080p/720p  │  │  256x256     │  │  256x256     │  │  +Accelerom.)│               │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘               │
│         │                  │                  │                  │                      │
│         │                  │                  │                  │                      │
│         └──────────────────┼──────────────────┼──────────────────┘                      │
│                            │                  │                                          │
│                            ▼                  ▼                                          │
│                    ┌───────────────────────┐                                             │
│                    │   DATA GATEWAY       │                                             │
│                    │   (C++ Bridge)       │                                             │
│                    └──────────┬───────────┘                                             │
│                               │                                                         │
│                               ▼                                                         │
│           ┌──────────────────────────────────────────────┐                              │
│           │         SHARED MEMORY BUFFER                 │                              │
│           │  [Tensor3D depth: 256x256x1]                 │                              │
│           │  [Tensor3D semantics: 256x256x1]             │                              │
│           │  [Matrix4x4 view-projection]                 │                              │
│           └──────────────────────────────────────────────┘                              │
│                               │                                                         │
│         ┌─────────────────────┼─────────────────────┐                                  │
│         │                     │                     │                                  │
│         ▼                     ▼                     ▼                                  │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐                             │
│  │   GPU Thread │    │   TFLite     │    │   Godot    │                             │
│  │  (Render)    │    │  Inference   │    │  Renderer  │                             │
│  │              │    │   Thread     │    │   (Main)   │                             │
│  │  - Draw      │    │  (NNAPI)     │    │  - Shader  │                             │
│  │  - Bind      │    │                │    │  - Mesh    │                             │
│  │  - Unbind    │    │                │    │  - Input   │                             │
│  └──────────────┘    └──────────────┘    └──────────────┘                             │
│         │                     │                     │                                  │
│         └─────────────────────┼─────────────────────┘                                  │
│                               ▼                                                         │
│                    ┌───────────────────────┐                                             │
│                    │   OUTPUT TEXTURE     │                                             │
│                    │  [Anime Pixelated    │                                             │
│                    │   2.5D Scene]        │                                             │
│                    └───────────────────────┘                                             │
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

### Tiempos de Ejecución por Componente (Frame Time Budget: 33.3ms @ 30 FPS)

| Componente | Tiempo Máximo | Operación |
|------------|---------------|-----------|
| **ARCore Data Acquisition** | ≤ 5 ms | Captura depth + semantics + camera |
| **Data Gateway (C++)** | ≤ 2 ms | Copia a shared memory, sincronización |
| **GPU Render Thread** | ≤ 10 ms | Draw calls, shader execution |
| **TFLite Inference (NNAPI)** | ≤ 20 ms | Tensor input → output (segmentación) |
| **Shader Pixelation** | ≤ 3 ms | Downsampling + cuantización |
| **Sync & Swap** | ≤ 1 ms | Framebuffer swap, vsync |
| **HEADROOM** | ≥ 1.3 ms | Margen para thermal throttling |

**Total Frame Time: ≤ 29.0 ms** (garantiza 30 FPS con margen)

---

## 3. Estructura Modular del Proyecto en Godot

```
res://
├── analytics/                    # Monitoring y metrics
│   ├── thermal_monitor.gd        # Detección de overheat
│   └── metrics_collector.gd      # FPS, memory, CPU
│
├── core/                         # Lógica principal
│   ├── main.tscn                 # Escena raíz
│   ├── world_manager.gd          # Gestión de escenario 3D
│   └── input_handler.gd          # Control táctil/camera
│
├── data/                         # Pipeline de datos
│   ├── arcore_bridge/            # Plugin nativo C++ (ARCore)
│   │   ├── CMakeLists.txt
│   │   ├── arcore_bridge.cpp
│   │   └── arcore_bridge.h
│   ├── tensor_converter.gd       # Conversion de tensors a texturas
│   └── shared_memory.gd          # Access a shared memory buffers
│
├── inference/                    # TFLite + NNAPI
│   ├── tflite_manager.gd         # Manager de modelos
│   ├── model/                    # Modelos TFLite
│   │   ├── mobilebert_segmentation.tflite
│   │   └── deeplab_v3.tflite
│   ├── thread_pool.gd            # ManagedThreadPool para inference
│   └── inference_worker.gd       # Worker que ejecuta en thread
│
├── render/                       # Shaders y renderizado
│   ├── shaders/
│   │   ├── anime_pixelate.glsl   # Fragment shader 2.5D
│   │   ├── depth_proj.glsl       # Vertex shader con depth
│   │   └── color_quant.glsl      # Cuantización paleta anime
│   ├── materials/
│   │   ├── anime_material.tres   # Material base
│   │   └── depth_material.tres   # Material con depth texture
│   └── pipeline/
│       ├── render_target.gd      # RenderTexture 2D
│       └── post_process.gd       # Chain de efectos
│
├── utils/                        # Utilidades
│   ├── timer.gd                  # High-precision timer
│   ├── math_ext.gd               # Matemáticas optimizadas
│   └── memory_opt.gd             # Limpieza de buffers
│
└── android/                      # Configuración Android
    ├── manifest.xml              # Permissions ARCore, NPU
    ├── build.gradle
    └── native_libs/              # .so libraries
        ├── libarcore.so
        └── libtensorflowlite_nnapi.so
```

### Division C++ / GDScript

| Componente | Lenguaje | Rationale |
|------------|----------|-----------|
| ARCore Bridge | C++ | Acceso nativo a Depth API, latencia mínima |
| Shared Memory | C++ | Transferencia rápida GPU ↔ CPU |
| TFLite Inference | C++ (NNAPI delegate) | Delegación a NPU/GPU sin bloqueo |
| Main Logic | GDScript | Lógica de game, orquestación |
| Shaders | GLSL | Procesamiento en GPU directo |
| Utilities | GDScript | Code maintainability |

---

## 4. Contrato de Datos Espaciales

### 4.1. Estructura de Tensor de Profundidad

```
struct DepthTensor {
    uint32_t width;        // 256 (resolución reducida)
    uint32_t height;       // 256
    uint32_t channels;     // 1 (depth map)
    float* data;           // [width * height] valores en metros
    float focal_length;    // Focal length de la cámara
    float baseline;        // Baseline entre cámaras
    uint64_t timestamp_ns; // Timestamp en nanosegundos
    float confidence;      // Confianza promedio del mapa
};
```

### 4.2. Estructura de Tensor de Semántica

```
struct SemanticTensor {
    uint32_t width;        // 256
    uint32_t height;       // 256
    uint32_t classes;      // 5 (floor, wall, object, sky, person)
    uint8_t* data;         // [width * height * classes] one-hot o labels
    uint64_t timestamp_ns; // Timestamp sincronizado con depth
};
```

### 4.3. Contrato de Shared Memory (Android ASharedMemory)

```
// Layout en memoria compartida (mapeado desde C++ a Godot)
struct SharedMemoryLayout {
    // Offset 0x0000: Depth Tensor
    DepthTensor depth_tensor;
    float depth_data[256 * 256];
    
    // Offset 0x02000: Semantic Tensor
    SemanticTensor semantic_tensor;
    uint8_t semantic_data[256 * 256 * 5];
    
    // Offset 0x03000: Camera Matrix (View-Projection)
    float view_matrix[16];      // 4x4 row-major
    float projection_matrix[16];// 4x4 row-major
    float camera_pos[3];        // x, y, z
    float camera_rot[4];        // quaternion (w, x, y, z)
    
    // Offset 0x03100: Metadata
    uint32_t frame_count;
    float fps;
    float temperature_celsius;
    int32_t cpu_usage_percent;
    
    // Padding + Checksum (para integridad)
    uint32_t checksum;
    uint8_t padding[256];
};
```

### 4.4. Tiempos de Transferencia

| Operación | Tiempo Estimado |
|-----------|-----------------|
| ARCore → Shared Memory (C++) | ≤ 2 ms |
| Shared Memory → GPU Texture | ≤ 3 ms |
| GPU → Fragment Shader | ≤ 1 ms |

**Total: ≤ 6 ms** (dentro del budget de 5 ms + headroom)

---

## 5. Arquitectura de Inferencia TFLite con NNAPI

### 5.1. Diagrama de Hilos

```
Main Thread (GDScript)               Inference Thread (ManagedThreadPool)
┌──────────────────┐                 ┌──────────────────┐
│                  │                 │                  │
│  - Input frame   │  ──────►       │  - Load tensor   │
│  - Queue buffer  │     │          │  - Run TFLite    │
│                  │     │          │  - Post-process  │
│  - Sync output   │ ◄──── ─        │  - Store result  │
│                  │                 │                  │
└──────────────────┘                 └──────────────────┘
         │                                     │
         │                                     │
    [Shared Memory] ◄─────────────────► [Output Tensor]
```

### 5.2. Delegación NNAPI

**Configuración obligatoria:**

```java
// Android native code (C++)
TfLiteDelegate* CreateNNAPIDelegate() {
    // Intentar delegar a NPU → GPU → CPU (en orden de preferencia)
    TFLiteSettings settings = {
        .accelerator = "npu",
        .fallback_to_cpu = false  // Si falla NPU, el sistema es inválido
    };
    return TFLiteNNAPIDelegateCreate(&settings);
}
```

**Requisitos de validación:**

1. Si NNAPI delegate falla → **Fallback TO CPU es inválido** (SLA de CPU ≤ 30%)
2. El sistema debe detectar si el dispositivo tiene NPU habilitado
3. Si no hay NPU → lanzar error en startup (no se puede ejecutar)

### 5.3. Modelo TFLite

**Requisitos del modelo:**

| Parámetro | Valor |
|-----------|-------|
| Input shape | `[1, 256, 256, 3]` (RGB) |
| Output shape | `[1, 256, 256, 5]` (5 clases) |
| Quantization | INT8 (para NNAPI) |
| Tamaño máximo | ≤ 25 MB (RAM limit) |
| Latencia | ≤ 25 ms (NNAPI delegate) |

**Modelo recomendado:** MobileBERT + DeepLab V3+ (customizado para segmentación en móvil)

### 5.4. Buffer Management

```
double-buffering para tensors de entrada/salida:

Input Buffers:
├── Buffer A: [256x256x3] float32 → TFLite (inference)
└── Buffer B: [256x256x3] float32 → ARCore (captura)

Output Buffers:
├── Buffer X: [256x256x5] uint8 → Shared Memory (segmentación)
└── Buffer Y: [256x256x5] uint8 → Shader (paleta)
```

---

## 6. Lógica de Fragment Shader (2.5D Anime Pixel Art)

### 6.1. Flujo de Procesamiento

```
Input: Depth Map (256x256) + RGB Texture (1080p) + Semantic Map
    │
    ├─ Downsample (GPU) → 128x128 (pixelación espacial)
    ├─ Depth-based parallax displacement (GPU)
    ├─ Color quantization → Anime palette (GPU)
    └─ Reproject on depth mesh → 3D scene
    │
Output: Rendered Frame (Anime 2.5D)
```

### 6.2. Fragment Shader (GLSL)

```glsl
// shaders/anime_pixelate.glsl

#version 300 es

precision mediump float;

// Input from vertex shader
in vec2 v_UV;
in vec2 v_DepthUV;

// Uniforms
uniform sampler2D u_ColorTexture;    // RGB texture (1080p)
uniform sampler2D u_DepthTexture;    // Depth map (256x256)
uniform sampler2D u_SemanticTexture; // Semantic map (256x256)

uniform vec2 u_ScreenResolution;
uniform vec2 u_PixelationScale;     // e.g., vec2(8.0, 8.0)
uniform vec2 u_ParallaxStrength;    // e.g., vec2(0.5, 0.5)
uniform float u_BloomThreshold;

// Anime color palette (quantized colors)
const vec3[16] ANIME_PALETTE = vec3[16](
    vec3(1.0, 0.95, 0.9),   // skin light
    vec3(0.9, 0.8, 0.7),    // skin mid
    vec3(0.7, 0.5, 0.4),    // skin shadow
    vec3(0.8, 0.85, 0.95),  // hair light
    vec3(0.6, 0.65, 0.8),   // hair mid
    vec3(0.4, 0.45, 0.6),   // hair shadow
    vec3(0.95, 0.9, 0.9),   // white
    vec3(0.8, 0.8, 0.8),    // gray
    vec3(0.6, 0.6, 0.6),    // dark gray
    vec3(0.1, 0.1, 0.1),    // black
    vec3(0.95, 0.8, 0.8),   // red
    vec3(0.8, 0.95, 0.8),   // green
    vec3(0.8, 0.8, 0.95),   // blue
    vec3(0.95, 0.95, 0.8),  // yellow
    vec3(0.95, 0.8, 0.95),  // magenta
    vec3(0.8, 0.95, 0.95)   // cyan
);

// Get quantized color from palette
vec3 quantizeToAnimePalette(vec3 color) {
    float minDist = 1e6;
    vec3 closestColor = vec3(0.0);
    
    for (int i = 0; i < 16; i++) {
        float dist = distance(color, ANIME_PALETTE[i]);
        if (dist < minDist) {
            minDist = dist;
            closestColor = ANIME_PALETTE[i];
        }
    }
    
    return closestColor;
}

// Pixelation: downsample by quantizing UVs
vec2 getPixelatedUV(vec2 uv, vec2 scale) {
    vec2 pixelUV = floor(uv * scale) / scale;
    return pixelUV;
}

void main() {
    // 1. Get pixelated UV for depth (coarse grid)
    vec2 pixelatedDepthUV = getPixelatedUV(v_DepthUV, u_PixelationScale);
    
    // 2. Sample depth value
    float depth = texture(u_DepthTexture, pixelatedDepthUV).r;
    
    // 3. Calculate parallax displacement based on depth
    // Closer objects (higher depth) shift more
    vec2 parallaxOffset = (depth - 0.5) * u_ParallaxStrength * 0.1;
    vec2 colorUV = v_UV + parallaxOffset;
    
    // 4. Sample color texture (with bilinear filtering)
    vec3 color = texture(u_ColorTexture, colorUV).rgb;
    
    // 5. Get semantic class (for material properties)
    int semanticClass = int(texture(u_SemanticTexture, pixelatedDepthUV).r * 255.0);
    
    // 6. Apply color quantization to anime palette
    vec3 animeColor = quantizeToAnimePalette(color);
    
    // 7. Apply semantic-based shading (outline, flat color, etc.)
    if (semanticClass == 0) { // floor
        animeColor *= 0.9; // darker
    } else if (semanticClass == 1) { // wall
        animeColor *= 0.95;
    } else if (semanticClass == 2) { // object
        animeColor *= 1.0;
    } else if (semanticClass == 3) { // sky
        animeColor = vec3(0.5, 0.7, 0.95); // blue sky
    } else if (semanticClass == 4) { // person
        animeColor *= 1.1; // brighter
    }
    
    // 8. Output final color
    gl_FragColor = vec4(animeColor, 1.0);
}
```

### 6.3. Vertex Shader

```glsl
// shaders/depth_proj.glsl

#version 300 es

in vec3 a_Vertex;
in vec2 a_TexCoord;

uniform mat4 u_ModelMatrix;
uniform mat4 u_ViewMatrix;
uniform mat4 u_ProjectionMatrix;
uniform sampler2D u_DepthTexture;

uniform float u_DepthMultiplier; // Scale depth for 3D effect
uniform vec2 u_PixelationScale;

out vec2 v_UV;
out vec2 v_DepthUV;

void main() {
    // Sample depth at this fragment location
    float depth = texture(u_DepthTexture, a_TexCoord).r;
    
    // Displace vertex along normal based on depth
    vec3 displacedVertex = a_Vertex;
    displacedVertex.z += depth * u_DepthMultiplier;
    
    // Calculate UV for pixelation (coarse grid)
    v_DepthUV = floor(a_TexCoord * u_PixelationScale) / u_PixelationScale;
    v_UV = a_TexCoord;
    
    gl_Position = u_ProjectionMatrix * u_ViewMatrix * u_ModelMatrix * vec4(displacedVertex, 1.0);
}
```

### 6.4. Parallax Math

**Fórmula de desplazamiento:**

```
displacement = (depth - 0.5) * parallaxStrength * baseline
```

Donde:
- `depth ∈ [0, 1]` (normalizado)
- `parallaxStrength ∈ [0, 1]` (controla la intensidad)
- `baseline = 0.1` (distancia entre cámaras ARCore)

---

## 7. Gestión de Memoria y Optimizaciones

### 7.1. Budget de Memoria Total: 450 MB

| Componente | Budget | Límite |
|------------|--------|--------|
| GPU Textures | ≤ 80 MB | Depth (256x256), RGB (1080p), Semantic (256x256) |
| TFLite Model | ≤ 25 MB | MobileBERT + DeepLab quantized |
| Input/Output Buffers | ≤ 30 MB | Double-buffered tensors |
| Godot Engine | ≤ 150 MB | Framework overhead |
| Native C++ | ≤ 50 MB | ARCore bridge, shared memory |
| Shaders/Materials | ≤ 10 MB | GLSL programs |
| UI/Assets | ≤ 30 MB | Textures, sounds, etc. |
| **HEADROOM** | ≤ 75 MB | Margen para picos |
| **TOTAL** | **≤ 450 MB** | SLA máximo |

### 7.2. Limpieza de Buffers (Memory Pool)

```gdscript
# utils/memory_opt.gd

class MemoryManager:
    var texture_pool = {}
    var buffer_pool = {}
    var max_pool_size = 5
    
    func acquire_texture(name, size):
        if texture_pool.has(name) and texture_pool[name].size == size:
            return texture_pool[name].pop()
        else:
            return create_new_texture(size)
    
    func release_texture(name, texture):
        if texture_pool.has(name) and len(texture_pool[name]) < max_pool_size:
            texture_pool[name].push(texture)
        else:
            texture.free()
    
    func clear_all_pools():
        for pool in [texture_pool, buffer_pool]:
            for key in pool:
                for item in pool[key]:
                    item.free()
            pool.clear()
```

### 7.3. Tensor LRU Cache

```gdscript
# inference/tensor_cache.gd

class TensorCache:
    var cache = {}  # {hash: [timestamp, tensor]}
    var max_size = 10
    var ttl_ms = 100  # Time-to-live: 100 ms
    
    func get_or_create(key, create_func):
        if cache.has(key) and OS.get_system_time_msecs() - cache[key][0] < ttl_ms:
            return cache[key][1]
        else:
            var tensor = create_func()
            _add_to_cache(key, tensor)
            return tensor
    
    func _add_to_cache(key, tensor):
        if len(cache) >= max_size:
            # Remove oldest
            var oldest_key = cache.keys()[0]
            cache[oldest_key][1].free()
            cache.erase(oldest_key)
        cache[key] = [OS.get_system_time_msecs(), tensor]
```

---

## 8. Fail-safe Térmico: Dynamic Resolution Scaling (DRS)

### 8.1. Mecanismo de Monitoreo

```
Thermal Monitor (every 500 ms):
    │
    ├─ Read CPU temperature
    ├─ Check FPS counter
    ├─ Check CPU usage
    │
    ▼
┌─────────────────────────────────────────────────────────┐
│ Decision Tree                                           │
├─────────────────────────────────────────────────────────┤
│ if (temp > 45°C OR fps < 25) →                        │
│    → Reduce resolution: 256 → 192 → 128 → 96          │
│    → Increase pixelation scale: 8 → 12 → 16           │
│    → Reduce inference frequency: 60fps → 30fps        │
│                                                         │
│ if (temp < 35°C AND fps > 45) →                       │
│    → Increase resolution (up to 256)                  │
│    → Return to normal settings                          │
└─────────────────────────────────────────────────────────┘
```

### 8.2. Dynamic Resolution Configuration

```gdscript
# analytics/thermal_monitor.gd

const DEFAULT_RESOLUTION = 256
const MIN_RESOLUTION = 96

var current_resolution = DEFAULT_RESOLUTION
var pixelation_scale = Vector2(8, 8)
var inference_fps = 60

func check_thermal():
    var temp = get_device_temperature()  # Android API
    var fps = metrics.get_avg_fps()
    var cpu = metrics.get_cpu_usage()
    
    # Thermal throttling
    if temp > 45 or fps < 25 or cpu > 50:
        reduce_resolution()
    elif temp < 35 and fps > 45 and cpu < 20:
        increase_resolution()
    
    # Dynamic inference rate
    if fps < 35:
        inference_fps = 30
    else:
        inference_fps = 60

func reduce_resolution():
    if current_resolution > MIN_RESOLUTION:
        current_resolution = int(current_resolution * 0.75)
        pixelation_scale *= 1.5
        update_shaders()

func increase_resolution():
    if current_resolution < DEFAULT_RESOLUTION:
        current_resolution = min(current_resolution * 1.33, DEFAULT_RESOLUTION)
        pixelation_scale = max(pixelation_scale / 1.5, Vector2(8, 8))
        update_shaders()
```

### 8.3. Thermal Shutdown (Last Resort)

```
Emergency Thermal Shutdown:
    if (temp > 55°C OR battery < 10% OR fps < 15):
        → Pause rendering
        → Stop inference
        → Show warning UI
        → Disable ARCore
        → Enter low-power mode
```

---

## 9. Criterios de Aceptación Técnicos (SLAs)

| SLA | Requerimiento | Mecanismo de Validación |
|-----|---------------|------------------------|
| **FPS** | ≥ 30 FPS (60 FPS ideal) | Timer en MainLoop, promedio 5s |
| **Frame Time** | < 33.3 ms | GPU timestamp queries |
| **Inference Latency** | < 25 ms | TFLite profiler, NNAPI delegate |
| **Memory** | < 450 MB | Android Debug Bridge (ADB) |
| **CPU Usage** | < 30% | NNAPI delegation obligatoria |
| **NPU Delegation** | 100% de inferencias en NPU | TFLite delegate check |
| **Thermal Throttling** | No después de 15 min | Temperature monitoring + DRS |
| **Memory Leaks** | 0 leaks en 30 min | Valgrind / Android Profiler |

---

## 10. Plan de Implementación

### Fase 1: Arquitectura Base (Aprobación requerida)
1. Crear estructura de carpetas en Godot
2. Implementar bridge C++ para ARCore
3. Configurar shared memory en Android
4. Implementar shader pipeline en GLSL

### Fase 2: Pipeline de Datos
1. Conectar ARCore Depth API
2. Implementar tensor converter
3. Sincronizar frames RGB + Depth

### Fase 3: Inferencia Edge AI
1. Integrar TFLite + NNAPI delegate
2. Implementar worker thread
3. Validar SLA de latencia

### Fase 4: Renderizado
1. Implementar shaders 2.5D Anime Pixel Art
2. Proyectar textura sobre depth mesh
3. Validar SLA de FPS

### Fase 5: Optimizaciones
1. Memory pool y buffer management
2. Dynamic Resolution Scaling
3. Thermal monitoring

---

## 11. Validación Técnica

### 11.1. Pruebas de Rendimiento

```
Benchmark Suite:
├── Frame Time Test (5s) → FPS ≥ 30
├── Inference Latency Test (100 frames) → < 25 ms avg
├── Memory Leak Test (30 min) → Valgrind clean
├── Thermal Test (15 min) → No throttling
└── CPU Usage Test → < 30% average
```

### 11.2. Tools de Monitoreo

| Tool | Uso |
|------|-----|
| **Android Profiler** | CPU, Memory, GPU |
| **Adreno GPU Profiler** | Shader performance |
| **TFLite Profiler** | Inference latency |
| **ADB** | Device metrics |

---

## 12. Referencias Técnicas

- [ARCore Depth API Documentation](https://developers.google.com/ar/develop/java/depth)
- [TensorFlow Lite NNAPI Delegate](https://www.tensorflow.org/lite/performance/nnapi)
- [Godot 4 C# vs GDScript](https://docs.godotengine.org/en/stable/tutorials/scripting/gdscript_vs_c_sharp.html)
- [OpenGL ES Shaders](https://www.khronos.org/opengl/wiki/Core_Language_(GLSL))

---

**Documento elaborado por:** Arquitecto de Software Senior  
**Versión:** 1.0  
**Fecha:** 31 Agosto 2026  
**Estado:** Pendiente de aprobación de arquitectura
