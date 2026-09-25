// color_quant.glsl
// Shader para cuantización de color a paleta anime
// Separate pass para cuantización sin pixelation

#version 300 es

precision mediump float;

in vec2 v_UV;
uniform sampler2D u_Texture;
uniform vec2 u_PixelationScale;

uniform vec3[16] ANIME_PALETTE = vec3[16](
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

void main() {
    vec2 pixelUV = floor(v_UV * u_PixelationScale) / u_PixelationScale;
    vec3 color = texture(u_Texture, pixelUV).rgb;
    vec3 animeColor = quantizeToAnimePalette(color);
    gl_FragColor = vec4(animeColor, 1.0);
}