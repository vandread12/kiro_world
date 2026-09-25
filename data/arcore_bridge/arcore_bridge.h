// arcore_bridge.h
// Bridge nativo C++ para ARCore Depth API
// Proporciona acceso a depth map y semantics via shared memory

#ifndef ARCORE_BRIDGE_H
#define ARCORE_BRIDGE_H

#include <cstdint>
#include <memory>
#include <android/asset_manager.h>

// Estructura de tensor de profundidad
struct DepthTensor {
    uint32_t width;
    uint32_t height;
    uint32_t channels;
    float* data;
    float focal_length;
    float baseline;
    uint64_t timestamp_ns;
    float confidence;
};

// Estructura de tensor semántico
struct SemanticTensor {
    uint32_t width;
    uint32_t height;
    uint32_t classes;
    uint8_t* data;
    uint64_t timestamp_ns;
};

// Estructura de cámara
struct CameraPose {
    float view_matrix[16];
    float projection_matrix[16];
    float position[3];
    float rotation[4]; // quaternion w, x, y, z
};

// Estructura de shared memory layout
struct SharedMemoryLayout {
    DepthTensor depth_tensor;
    float depth_data[256 * 256];
    
    SemanticTensor semantic_tensor;
    uint8_t semantic_data[256 * 256 * 5];
    
    CameraPose camera;
    uint32_t frame_count;
    float fps;
    float temperature_celsius;
    int32_t cpu_usage_percent;
    uint32_t checksum;
    uint8_t padding[256];
};

// Clase principal del bridge
class ARCoreBridge {
public:
    ARCoreBridge();
    ~ARCoreBridge();
    
    // Inicialización
    bool initialize(AAssetManager* asset_manager);
    void shutdown();
    
    // Captura de frames
    bool captureFrame();
    
    // Getters
    DepthTensor* getDepthTensor() { return &m_depth_tensor; }
    SemanticTensor* getSemanticTensor() { return &m_semantic_tensor; }
    CameraPose* getCameraPose() { return &m_camera_pose; }
    uint32_t getFrameCount() { return m_frame_count; }
    
    // Shared memory
    bool createSharedMemory(const char* name, size_t size);
    void* getSharedMemoryPointer() { return m_shared_memory_ptr; }
    void destroySharedMemory();
    
private:
    // ARCore handle (void* para evitar dependencia de headers)
    void* m_arcore_session;
    
    // Tensors
    DepthTensor m_depth_tensor;
    SemanticTensor m_semantic_tensor;
    CameraPose m_camera_pose;
    uint32_t m_frame_count;
    
    // Shared memory
    int m_shared_memory_fd;
    void* m_shared_memory_ptr;
    size_t m_shared_memory_size;
    
    // Metadata
    float m_fps;
    float m_temperature;
    int32_t m_cpu_usage;
    
    // Helpers
    void computeChecksum();
    uint32_t calculateChecksum(const uint8_t* data, size_t size);
};

#endif // ARCORE_BRIDGE_H