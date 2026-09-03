#include <metal_stdlib>

#include "../common.metal"
#include "../light.metal"

using namespace metal;

struct ToonData {
    uint directional_light_count;
    bool use_albedo_texture;
    float4 albedo_color;
    float3 eye_position;
    float alpha_cutoff;
    float2 tiling;
    float2 offset;
};

fragment FragmentOutput fragment_toon(
    RasterizerData input                           [[stage_in]],
    constant Globals& globals                      [[buffer(0)]],
    constant ToonData& material_data               [[buffer(1)]],
    constant DirectionalLight* directional_lights  [[buffer(2)]],
    texture2d<half> albedo                         [[texture(3)]],
    sampler albedo_sampler                         [[sampler(4)]]
) {
    float2 uv = input.uv0 * material_data.tiling + material_data.offset;
    
    float3 diffuse = float3(0.0);
    
    float4 albedo_sample = material_data.use_albedo_texture ? float4(albedo.sample(albedo_sampler, uv)) : float4(1.0);
    float4 albedo_output = material_data.albedo_color * albedo_sample;
    
    if (albedo_output.a < material_data.alpha_cutoff) {
        discard_fragment();
    }

    float3 view_direction = normalize(material_data.eye_position - input.fragment_position);
    
    float3 normal = normalize(input.normal);

    float sky_intensity = 0.5;
    float ground_intensity = 0.3;

    float sky_factor = saturate(normal.y);
    float ground_factor = saturate(-normal.y);

    float3 ambient = float3(0.2);
    ambient += sky_factor * float3(0.5, 0.5, 0.6) * sky_intensity +
        ground_factor * float3(0.3, 0.25, 0.2) * ground_intensity;
    
    float rim = 1.0 - saturate(dot(normal, view_direction));
    float rim_intensity = 0.8;
    rim = smoothstep(0.7, 0.9, rim) * rim_intensity;

    for (uint i = 0; i < material_data.directional_light_count; i++) {
        DirectionalLight light = directional_lights[i];
        
        float ndotl = dot(normal, -light.direction);
        float diff = smoothstep(0.2, 0.8, ndotl);
        
        float wrapped_ndotl = max(ndotl * 0.5 + 0.5, 0.0);
        diffuse += diff * light.color * light.intensity;
        rim *= wrapped_ndotl;
    }
    
    FragmentOutput output;
    
    float3 color = float3(albedo_output) * (diffuse + ambient) + rim;
    output.color = float4(color, albedo_output.a);
    output.normal = float4(normal * 0.5 + 0.5, 1.0);
    
    return output;
}
