# inference_worker.gd
# Worker thread para ejecutar TFLite sin bloquear el main thread

extends Node

# Variables
var is_running = false
var task_queue = []
var result_queue = []

# Inicialización
func _ready():
    is_running = true
    print("[InferenceWorker] Worker started")

# Process loop
func _process(delta):
    if not is_running:
        return
    
    # Process tasks
    while task_queue.size() > 0:
        var task = task_queue.pop_front()
        process_task(task)

# Add task to queue
func enqueue_task(task: Dictionary):
    task_queue.append(task)

# Process single task
func process_task(task: Dictionary):
    # Run inference
    var result = run_inference(task.input_data)
    
    # Store result
    result_queue.append({
        "result": result,
        "callback": task.callback,
        "id": task.id
    })

# Run inference (wrapper)
func run_inference(input_data: PackedByteArray) -> PackedByteArray:
    # Call TFLite manager
    if has_node("/root/TFLiteManager"):
        var manager = get_node("/root/TFLiteManager")
        # In a real implementation, this would be a proper bridge
        return PackedByteArray()
    return PackedByteArray()

# Get results
func get_results() -> Array:
    var results = result_queue.duplicate()
    result_queue.clear()
    return results

# Cleanup
func _notification(what):
    if what == NOTIFICATION_PREDELETE:
        is_running = false