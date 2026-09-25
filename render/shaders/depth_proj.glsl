// depth_proj.glsl
// Vertex shader con proyección basada en depth map
// Desplaza vértices según mapa de profundidad para efecto parallax 3D

#version 300 es

in vec3 a_Vertex;
in vec2 a_TexCoord;

uniform mat4 u_ModelMatrix;
uniform mat4 u_ViewMatrix;
uniform mat4 u_ProjectionMatrix;
uniform sampler2D u_DepthTexture;

uniform float u_DepthMultiplier; // Scale depth for 3D effect
uniform vec2 u_PixelationScale;

out vec2 v_UV;
out vec2 v_DepthUV;

void main() {
    // Sample depth at this fragment location
    float depth = texture(u_DepthTexture, a_TexCoord).r;
    
    // Displace vertex along normal based on depth
    // Normal approximation: z-axis for planar mesh
    vec3 displacedVertex = a_Vertex;
    displacedVertex.z += depth * u_DepthMultiplier;
    
    // Calculate UV for pixelation (coarse grid)
    v_DepthUV = floor(a_TexCoord * u_PixelationScale) / u_PixelationScale;
    v_UV = a_TexCoord;
    
    gl_Position = u_ProjectionMatrix * u_ViewMatrix * u_ModelMatrix * vec4(displacedVertex, 1.0);
}