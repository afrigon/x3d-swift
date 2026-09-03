import XEngineCore
import simd
import Foundation

public struct MaterialTemplate {
    public var name: String?
    public var ambientColor: simd_float3 = Color.white.rgb
    public var diffuseColor: simd_float3 = Color.white.rgb
    public var diffuseTexture: URL?
    public var specularColor: simd_float3 = Color.black.rgb
    public var specularHighlight: Float = 250
    public var opticalDensity: Float = 1.5
    public var dissolve: Float = 1
    public var illuminationModel: Int = 1
}
