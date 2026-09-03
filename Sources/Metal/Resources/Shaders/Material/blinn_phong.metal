#include <metal_stdlib>

#include "../common.metal"
#include "../light.metal"

using namespace metal;

struct BlinnPhongData {
    uint directional_light_count;
    bool use_albedo_texture;
    bool use_normal_map;
    float4 albedo_color;
    float specular_strength;
    float shininess;
    float3 eye_position;
    float alpha_cutoff;
    float2 tiling;
    float2 offset;
};

fragment FragmentOutput fragment_blinn_phong(
    RasterizerData input                           [[stage_in]],
    constant Globals& globals                      [[buffer(0)]],
    constant BlinnPhongData& material_data         [[buffer(1)]],
    constant DirectionalLight* directional_lights  [[buffer(2)]],
    texture2d<half> albedo                         [[texture(3)]],
    sampler albedo_sampler                         [[sampler(4)]],
    texture2d<half> normal_map                     [[texture(5)]],
    sampler normal_map_sampler                     [[sampler(6)]]
) {
    float2 uv = input.uv0 * material_data.tiling + material_data.offset;
    
    float3 diffuse = float3(0.0);
    float3 specular = float3(0.0);
    
    float4 albedo_sample = material_data.use_albedo_texture ? float4(albedo.sample(albedo_sampler, uv)) : float4(1.0);
    float4 albedo_output = material_data.albedo_color * albedo_sample;
    
    if (albedo_output.a < material_data.alpha_cutoff) {
        discard_fragment();
    }

    float3 view_direction = normalize(material_data.eye_position - input.fragment_position);
    
    float3 normal = normalize(input.normal);
    float3 tangent = normalize(input.tangent);

    if (material_data.use_normal_map) {
        // Gram-Schmidt: interpolation across the triangle leaves T and N non-orthogonal.
        tangent = normalize(tangent - normal * dot(normal, tangent));
        float3 bitangent = cross(normal, tangent);
        float3 normal_sample = normalize(float3(normal_map.sample(normal_map_sampler, uv).xyz) * 2.0 - 1.0);
        normal = normalize(float3x3(tangent, bitangent, normal) * normal_sample);
    }
    
    float3 ambient = float3(0.1);
    
    for (uint i = 0; i < material_data.directional_light_count; i++) {
        DirectionalLight light = directional_lights[i];
        
        float ndotl = max(dot(normal, -light.direction), 0.0);
        diffuse += ndotl * light.color * light.intensity;
        
        // Blinn-Phong: half vector between the light and the eye, not the reflection vector.
        float3 half_direction = normalize(view_direction - light.direction);
        float spec = ndotl > 0.0 ? pow(max(dot(normal, half_direction), 0.0), material_data.shininess) : 0.0;
        specular += spec * material_data.specular_strength * light.color * light.intensity;
    }
    
    FragmentOutput output;
    
    output.color = albedo_output * float4(diffuse + specular + ambient, 1.0);
    output.normal = float4(normal * 0.5 + 0.5, 1.0);
    
    return output;
}
