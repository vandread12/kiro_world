# memory_opt.gd
# Gestión de memoria y optimizaciones
# Memory pool y limpieza de buffers obsoletos

class MemoryManager:
    # Pool de texturas reutilizables
    var texture_pool = {}
    var buffer_pool = {}
    var max_pool_size = 5
    
    # Estadísticas
    var total_textures_created = 0
    var total_textures_reused = 0
    
    # Inicialización
    func _init():
        print("[MemoryManager] Inicializando pool de memoria")
    
    # Adquirir textura del pool o crear nueva
    func acquire_texture(name: String, size: Vector2, format: int = Image.FORMAT_RGBA8) -> Texture2D:
        var key = "%s_%s" % [name, size]
        
        if texture_pool.has(key) and len(texture_pool[key]) > 0:
            var texture = texture_pool[key].pop()
            total_textures_reused += 1
            return texture
        
        total_textures_created += 1
        return create_new_texture(size, format)
    
    # Devolver textura al pool
    func release_texture(name: String, texture: Texture2D):
        var size = texture.get_width()
        var key = "%s_%s" % [name, size]
        
        if not texture_pool.has(key):
            texture_pool[key] = []
        
        if len(texture_pool[key]) < max_pool_size:
            texture_pool[key].push(texture)
        else:
            texture.free()
    
    # Crear textura nueva
    func create_new_texture(size: Vector2, format: int) -> ImageTexture:
        var image = Image.new()
        image.create(int(size.x), int(size.y), false, format)
        return ImageTexture.create_from_image(image)
    
    # Adquirir buffer (array de bytes)
    func acquire_buffer(size: int) -> PackedByteArray:
        if buffer_pool.has(size) and len(buffer_pool[size]) > 0:
            return buffer_pool[size].pop()
        return PackedByteArray()
    
    # Devolver buffer al pool
    func release_buffer(buffer: PackedByteArray):
        var size = buffer.size()
        if not buffer_pool.has(size):
            buffer_pool[size] = []
        
        if len(buffer_pool[size]) < max_pool_size:
            buffer_pool[size].push(buffer)
        else:
            buffer = PackedByteArray()
    
    # Limpiar todos los pools
    func clear_all_pools():
        for pool in [texture_pool, buffer_pool]:
            for key in pool:
                for item in pool[key]:
                    if typeof(item) == TYPE_OBJECT and not item.is_null():
                        item.free()
            pool.clear()
        
        print("[MemoryManager] Pools limpiados")
    
    # Mostrar estadísticas
    func get_stats() -> Dictionary:
        var stats = {
            "total_created": total_textures_created,
            "total_reused": total_textures_reused,
            "reuse_rate": 0.0,
            "texture_pools": 0,
            "buffer_pools": 0
        }
        
        if total_textures_created > 0:
            stats.reuse_rate = float(total_textures_reused) / float(total_textures_created)
        
        for pool in [texture_pool, buffer_pool]:
            stats.texture_pools = len(pool)
        
        return stats