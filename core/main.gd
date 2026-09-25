# main.gd
# Script principal y entry point
# Inicializa todos los sistemas y coordina el loop principal

extends Node

# Components
@onready var world_manager = $WorldManager
@onready var thermal_monitor = $ThermalMonitor
@onready var input_handler = $InputHandler

# Inicialización
func _ready():
    print("=== Anime Pixel AR ===")
    print("Iniciando sistema...")
    
    # Start thermal monitoring
    thermal_monitor.connect("resolution_changed", Callable(self, "_on_resolution_changed"))
    thermal_monitor.connect("thermal_warning", Callable(self, "_on_thermal_warning"))
    
    # Start input handler
    input_handler.setup()
    
    # Start world manager
    world_manager._ready()
    
    print("Sistema listo - FPS objetivo: 30+")
    
    # Show welcome message
    show_welcome_message()

# Setup
func setup():
    set_process(true)

# Main loop
func _process(delta):
    # Update world manager
    world_manager._process(delta)

# Input handling
func _input(event):
    input_handler.handle_input(event)

# Resolution change callback
func _on_resolution_changed(new_res: int, pixelation: Vector2):
    print("[Main] Resolución cambiada: %dx%d (pixelation: %s)" % [
        new_res, new_res * 3 / 4, pixelation])
    
    # Update world manager
    if world_manager.has_method("update_shader_params"):
        world_manager.update_shader_params()

# Thermal warning callback
func _on_thermal_warning(temp: float):
    print("[Main] WARNING TÉRMICO: %s°C" % temp)

# Welcome message
func show_welcome_message():
    print("")
    print("=== Controles ===")
    print("- Tap: Mover cámara")
    print("- Swipe: Rotar escenario")
    print("- Pinch: Zoom")
    print("")
    print("=== SLAs ===")
    print("- FPS: ≥ 30 (target: 60)")
    print("- Latencia: < 25ms (TFLite)")
    print("- RAM: < 450 MB")
    print("- CPU: < 30%")
    print("- Thermal: < 45°C (DRS activo)")
    print("")

# Cleanup
func _notification(what):
    if what == NOTIFICATION_PREDELETE:
        print("=== Anime Pixel AR - Shutdown ===")