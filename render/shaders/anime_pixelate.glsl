// anime_pixelate.glsl
// Fragment shader para efecto 2.5D Anime Pixel Art
// Aplica downsampling espacial, cuantización de color y proyección sobre depth

#version 300 es

precision mediump float;

// Input from vertex shader
in vec2 v_UV;
in vec2 v_DepthUV;

// Uniforms
uniform sampler2D u_ColorTexture;      // RGB texture (1080p)
uniform sampler2D u_DepthTexture;      // Depth map (256x256)
uniform sampler2D u_SemanticTexture;   // Semantic map (256x256)

uniform vec2 u_ScreenResolution;
uniform vec2 u_PixelationScale;        // e.g., vec2(8.0, 8.0)
uniform vec2 u_ParallaxStrength;       // e.g., vec2(0.5, 0.5)
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