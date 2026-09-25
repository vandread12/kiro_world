# input_handler.gd
# Manejo de inputs táctiles y multitouch
# Gestiona cámara y navegación en el escenario 3D

extends Node

# Variables
var camera_node = null
var is_touching = false
var last_touch_pos = Vector2.ZERO
var touch_id = -1

# Configuración
var pan_sensitivity = 0.005
var rotate_sensitivity = 0.002
var zoom_sensitivity = 0.05

# Inicialización
func setup():
    print("[InputHandler] Configurado")

# Handle input
func handle_input(event):
    if event is InputEventScreenTouch:
        handle_touch(event)
    elif event is InputEventScreenDrag:
        handle_drag(event)
    elif event is InputEventMagnifyGesture:
        handle_zoom(event)
    elif event is InputEventPanGesture:
        handle_pan(event)

# Touch handling
func handle_touch(event):
    if event.is_pressed():
        is_touching = true
        touch_id = event.get_index()
        last_touch_pos = event.get_position()
    else:
        is_touching = false
        touch_id = -1

# Drag handling
func handle_drag(event):
    if not is_touching or event.get_index() != touch_id:
        return
    
    var current_pos = event.get_position()
    var delta = current_pos - last_touch_pos
    
    # Rotate camera
    if camera_node != null:
        camera_node.rotate_y(-delta.x * rotate_sensitivity)
        camera_node.rotate_object_local(Vector3(1, 0, 0), -delta.y * rotate_sensitivity)
    
    last_touch_pos = current_pos

# Zoom handling
func handle_zoom(event):
    if camera_node != null:
        var zoom = camera_node.translation.z + event.get_factor() * zoom_sensitivity
        zoom = clamp(zoom, 1.0, 10.0)
        camera_node.translation.z = zoom

# Pan handling
func handle_pan(event):
    if camera_node != null:
        camera_node.translation.x -= event.get_delta().x * pan_sensitivity
        camera_node.translation.y += event.get_delta().y * pan_sensitivity

# Set camera
func set_camera(node):
    camera_node = node