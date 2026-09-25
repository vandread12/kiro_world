# world_manager.gd
# Manager del escenario 3D y renderizado
# Orquesta la integración de ARCore, inferencia y shaders

extends Node3D

# Components
@onready var arcore_bridge = $ARCoreBridge
@onready var tflite_manager = $TFLiteManager
@onready var thermal_monitor = $ThermalMonitor
@onready var render_pipeline = $RenderPipeline

# Shaders
var anime_pixelate_shader: Shader
var depth_proj_shader: Shader

# Materials
var anime_material: StandardMaterial3D
var depth_material: StandardMaterial3D

# Mesh
var plane_mesh: PlaneMesh

# Render targets
var render_texture: RenderTexture2D
var depth_texture: RenderTexture2D

# Parameters
var pixelation_scale = Vector2(8, 8)
var parallax_strength = Vector2(0.5, 0.5)
var depth_multiplier = 0.1

# Inicialización
func _ready():
    print("[WorldManager] Inicializando")
    
    # Load shaders
    anime_pixelate_shader = load("res://render/shaders/anime_pixelate.glsl")
    depth_proj_shader = load("res://render/shaders/depth_proj.glsl")
    
    # Create materials
    anime_material = StandardMaterial3D.new()
    anime_material.set_shader(anime_pixelate_shader)
    anime_material.set_shader_parameter("u_PixelationScale", pixelation_scale)
    anime_material.set_shader_parameter("u_ParallaxStrength", parallax_strength)
    
    depth_material = StandardMaterial3D.new()
    depth_material.set_shader(depth_proj_shader)
    depth_material.set_shader_parameter("u_DepthMultiplier", depth_multiplier)
    
    # Create plane mesh
    plane_mesh = PlaneMesh.new()
    plane_mesh.set_size(Vector2(4, 3))
    plane_mesh.set_subdivisions(Subdivisions.SUBDIVISION_256)
    
    # Set material
    plane_mesh.set_material_override(anime_material)
    
    # Add to scene
    var mesh_instance = MeshInstance3D.new()
    mesh_instance.set_mesh(plane_mesh)
    add_child(mesh_instance)
    
    # Create render targets
    create_render_targets()
    
    # Start loop
    set_process(true)

# Create render targets
func create_render_targets():
    var res = thermal_monitor.current_resolution
    
    render_texture = RenderTexture2D.new()
    render_texture.set_size(Vector2i(res, res * 3 / 4))
    
    depth_texture = RenderTexture2D.new()
    depth_texture.set_size(Vector2i(res, res))

# Update shader params
func update_shader_params():
    anime_material.set_shader_parameter("u_PixelationScale", pixelation_scale)
    anime_material.set_shader_parameter("u_ParallaxStrength", parallax_strength)
    
    depth_material.set_shader_parameter("u_DepthMultiplier", depth_multiplier)

# Main loop
func _process(delta):
    if thermal_monitor.is_processing():
        # Update frame
        update_frame()

# Update single frame
func update_frame():
    # 1. Capture from ARCore
    if arcore_bridge.is_initialized():
        arcore_bridge.capture_frame()
    
    # 2. Run inference (async)
    var depth_data = arcore_bridge.get_depth_tensor()
    if depth_data != null:
        tflite_manager.run_inference(depth_data)
    
    # 3. Render with shaders
    render_scene()

# Render scene
func render_scene():
    # Set depth texture
    var depth_texture_2d = arcore_bridge.get_depth_texture()
    depth_material.set_shader_parameter("u_DepthTexture", depth_texture_2d)
    
    # Update mesh
    plane_mesh.set_material_override(anime_material)
    
    # Render to texture
    render_pipeline.render_to_texture(render_texture)

# Pause
func pause():
    set_process(false)
    print("[WorldManager] Paused")

# Cleanup
func _notification(what):
    if what == NOTIFICATION_PREDELETE:
        if render_texture != null:
            render_texture.free()
        if depth_texture != null:
            depth_texture.free()