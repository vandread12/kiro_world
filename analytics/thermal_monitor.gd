# thermal_monitor.gd
# Monitor térmico y Dynamic Resolution Scaling (DRS)
# Previene thermal throttling ajustando resolución dinámicamente

extends Node

# Configuración
const DEFAULT_RESOLUTION = 256
const MIN_RESOLUTION = 96
const MAX_TEMP = 45.0
const CRITICAL_TEMP = 55.0
const LOW_TEMP_THRESHOLD = 35.0

# Variables
var current_resolution = DEFAULT_RESOLUTION
var pixelation_scale = Vector2(8, 8)
var inference_fps = 60
var resolution_stage = 0  # 0: normal, 1: reduced, 2: minimal

# Métricas
var temp_history = []
var fps_history = []

# Callbacks
signal thermal_warning(temp)
signal resolution_changed(new_res, pixelation)

# Inicialización
func _ready():
    print("[ThermalMonitor] Inicializado")
    set_process(true)

# Update loop
func _process(delta):
    if Engine.is_in_editor_hint():
        return
    
    # Monitor cada 500ms
    if randf() < 0.016:  # Aprox 60fps
        check_thermal()
        update_metrics()

# Verificar temperatura y ajustar
func check_thermal():
    var temp = get_device_temperature()
    var fps = get_avg_fps()
    var cpu = get_cpu_usage()
    
    # Thermal throttling
    if temp > MAX_TEMP or fps < 25 or cpu > 50:
        if resolution_stage > 0:
            reduce_resolution()
    elif temp < LOW_TEMP_THRESHOLD and fps > 45 and cpu < 20:
        if resolution_stage < 0:
            increase_resolution()
    
    # Dynamic inference rate
    if fps < 35:
        inference_fps = 30
    else:
        inference_fps = 60
    
    # Emergency shutdown
    if temp > CRITICAL_TEMP:
        emergency_shutdown()

# Reducir resolución
func reduce_resolution():
    if current_resolution > MIN_RESOLUTION:
        current_resolution = int(current_resolution * 0.75)
        pixelation_scale *= 1.5
        resolution_stage += 1
        
        emit_signal("resolution_changed", current_resolution, pixelation_scale)
        emit_signal("thermal_warning", get_device_temperature())
        
        update_shaders()
        print("[ThermalMonitor] Resolución reducida: %dpx" % current_resolution)

# Aumentar resolución
func increase_resolution():
    if current_resolution < DEFAULT_RESOLUTION:
        current_resolution = min(int(current_resolution * 1.33), DEFAULT_RESOLUTION)
        pixelation_scale = max(pixelation_scale / 1.5, Vector2(8, 8))
        resolution_stage -= 1
        
        emit_signal("resolution_changed", current_resolution, pixelation_scale)
        update_shaders()
        print("[ThermalMonitor] Resolución aumentada: %dpx" % current_resolution)

# Actualizar shaders
func update_shaders():
    # Notificar a los shaders del cambio
    if has_node("/root/WorldManager"):
        var wm = get_node("/root/WorldManager")
        if wm.has_method("update_shader_params"):
            wm.update_shader_params()

# Monitor de métricas
func update_metrics():
    temp_history.append(get_device_temperature())
    fps_history.append(get_avg_fps())
    
    # Mantener solo últimas 60 mediciones
    if len(temp_history) > 60:
        temp_history.pop_front()
    if len(fps_history) > 60:
        fps_history.pop_front()

# Getters
func get_avg_temp() -> float:
    if len(temp_history) == 0:
        return get_device_temperature()
    return sum(temp_history) / len(temp_history)

func get_avg_fps() -> float:
    if len(fps_history) == 0:
        return Engine.get_frames_per_second()
    return sum(fps_history) / len(fps_history)

func get_cpu_usage() -> int:
    # En Android, leer de /proc/cpuinfo o usar NDK
    # Para desarrollo, return dummy
    return randi() % 40

func get_device_temperature() -> float:
    # En Android, usar SensorManager
    # Para desarrollo, return dummy
    return 30.0 + randf() * 5.0

# Emergency shutdown
func emergency_shutdown():
    print("[ThermalMonitor] SHUTDOWN CRÍTICO - Temp: %s°C" % get_device_temperature())
    
    # Pausar renderizado
    if has_node("/root/WorldManager"):
        var wm = get_node("/root/WorldManager")
        wm.pause()
    
    # Stop inference
    if has_node("/root/InferenceManager"):
        var im = get_node("/root/InferenceManager")
        im.stop()
    
    # Show warning
    if has_node("/root/UIManager"):
        var ui = get_node("/root/UIManager")
        ui.show_critical_warning()
    
    # Deshabilitar ARCore
    if has_node("/root/ARCoreBridge"):
        var bridge = get_node("/root/ARCoreBridge")
        bridge.shutdown()