# tflite_manager.gd
# Manager de TensorFlow Lite con NNAPI delegate
# Gestiona modelos y ejecución de inferencia asíncrona

extends Node

# Paths de modelos
const MODEL_PATH = "res://inference/model/deeplab_v3.tflite"
const NUM_THREADS = 2

# Variables
var interpreter = null
var input_tensor = null
var output_tensor = null
var is_initialized = false

# Thread pool
var thread_pool = null
var worker_id = 0

# Callbacks
signal inference_complete(result)
signal inference_error(error)

# Inicialización
func _ready():
    print("[TFLiteManager] Inicializando")
    initialize()

# Inicializar TFLite
func initialize():
    # Cargar modelo
    var model_data = load_model(MODEL_PATH)
    if model_data == null:
        emit_signal("inference_error", "No se pudo cargar el modelo")
        return
    
    # Create interpreter
    interpreter = TFLiteInterpreter.new()
    if not interpreter.initialize(model_data):
        emit_signal("inference_error", "Fallo al inicializar interpreter")
        return
    
    # Set NNAPI delegate (obligatorio)
    if not interpreter.set_delegate("nnapi"):
        emit_signal("inference_error", "NNAPI delegate no disponible")
        return
    
    # Allocate tensors
    if not interpreter.allocate_tensors():
        emit_signal("inference_error", "Fallo al asignar tensors")
        return
    
    # Get input/output details
    var input_details = interpreter.get_input_details()
    var output_details = interpreter.get_output_details()
    
    if input_details.size() == 0 or output_details.size() == 0:
        emit_signal("inference_error", "Sin tensors de input/output")
        return
    
    input_tensor = input_details[0]
    output_tensor = output_details[0]
    
    is_initialized = true
    print("[TFLiteManager] Inicializado - Input: %s, Output: %s" % [
        input_tensor.shape, output_tensor.shape])

# Cargar modelo
func load_model(path: String) -> PackedByteArray:
    var file = FileAccess.open(path, FileAccess.READ)
    if file == null:
        return PackedByteArray()
    
    var size = file.get_length()
    var data = file.get_buffer(size)
    file.close()
    
    return data

# Ejecutar inferencia (asíncrona)
func run_inference(input_data: PackedByteArray, callback: String = "", callback_id: int = 0):
    if not is_initialized:
        emit_signal("inference_error", "TFLite no inicializado")
        return
    
    # Crear worker task
    var task = {
        "input_data": input_data,
        "callback": callback,
        "callback_id": callback_id,
        "timestamp": OS.get_system_time_msecs()
    }
    
    # Ejecutar en thread pool
    thread_pool.queue_callback("_inference_worker", [task])

# Worker de inferencia
func _inference_worker(task: Dictionary):
    var input_data = task.input_data
    
    # Copy input to tensor
    interpreter.copy_to_tensor(input_tensor, input_data)
    
    # Run inference
    var start_time = OS.get_system_time_msecs()
    var success = interpreter.invoke()
    var elapsed = OS.get_system_time_msecs() - start_time
    
    # Check latency
    if elapsed > 25:
        print("[TFLiteManager] WARNING: Latencia alta: %dms" % elapsed)
    
    if not success:
        emit_signal("inference_error", "Inferencia falló")
        return
    
    # Get output
    var output_data = interpreter.copy_from_tensor(output_tensor)
    
    # Post-process (opcional: apply softmax, etc.)
    output_data = post_process(output_data)
    
    # Notify
    if task.callback != "":
        call_deferred(task.callback, output_data, task.callback_id)
    else:
        emit_signal("inference_complete", output_data)

# Post-process output
func post_process(data: PackedByteArray) -> PackedByteArray:
    # Apply softmax a cada pixel
    var output_size = 256 * 256 * 5  # 5 clases
    var result = PackedByteArray()
    
    for i in range(0, output_size, 5):
        # Convertir a floats
        var floats = []
        for j in range(5):
            floats.append(float(data[i + j]) / 255.0)
        
        # Softmax
        var max_val = max(floats)
        var sum_exp = 0.0
        for f in floats:
            sum_exp += exp(f - max_val)
        
        for j in range(5):
            var prob = exp(floats[j] - max_val) / sum_exp
            result.append(int(prob * 255))
    
    return result

# Cleanup
func _notification(what):
    if what == NOTIFICATION_PREDELETE:
        if interpreter != null:
            interpreter.close()

# Clase辅助 TFLiteInterpreter (placeholder)
class TFLiteInterpreter:
    var m_interpreter = null
    
    func initialize(model_data: PackedByteArray) -> bool:
        # Create TFLite interpreter
        m_interpreter = create_interpreter(model_data)
        return m_interpreter != null
    
    func set_delegate(delegate_name: String) -> bool:
        # Set NNAPI delegate
        return set_nnapi_delegate(m_interpreter)
    
    func allocate_tensors() -> bool:
        return allocate_tensors(m_interpreter)
    
    func get_input_details() -> Array:
        return get_tensor_details(m_interpreter, true)
    
    func get_output_details() -> Array:
        return get_tensor_details(m_interpreter, false)
    
    func copy_to_tensor(detail: Dictionary, data: PackedByteArray):
        copy_tensor_data(m_interpreter, detail["index"], data)
    
    func copy_from_tensor(detail: Dictionary) -> PackedByteArray:
        return get_tensor_data(m_interpreter, detail["index"])
    
    func invoke() -> bool:
        return invoke_interpreter(m_interpreter)
    
    func close():
        close_interpreter(m_interpreter)
    
    # Native methods (implemented in C++)
    static func create_interpreter(model_data: PackedByteArray) -> int:
        return 0
    
    static func set_nnapi_delegate(interpreter: int) -> bool:
        return true
    
    static func allocate_tensors(interpreter: int) -> bool:
        return true
    
    static func get_tensor_details(interpreter: int, is_input: bool) -> Array:
        return []
    
    static func copy_tensor_data(interpreter: int, index: int, data: PackedByteArray):
        pass
    
    static func get_tensor_data(interpreter: int, index: int) -> PackedByteArray:
        return PackedByteArray()
    
    static func invoke_interpreter(interpreter: int) -> bool:
        return true
    
    static func close_interpreter(interpreter: int):
        pass