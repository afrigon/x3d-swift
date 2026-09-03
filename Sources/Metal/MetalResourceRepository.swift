import MetalKit
import XEngineCore

public class MetalResourceRepository: ResourceRepository {
    public var materials: [String: Material] = [:]
    var meshes: [String: MetalMesh] = [:]
    var textures: [String: MetalTexture] = [:]
    
    var shaders: [String: MTLRenderPipelineState] = [:]
    var samplers: [TextureOptions: MTLSamplerState] = [:]
    
    let textureLoader: MTKTextureLoader

    weak var device: MTLDevice?
    
    init(device: MTLDevice) {
        self.device = device
        self.textureLoader = MTKTextureLoader(device: device)
    }
    
    public func meshExists(name: String) -> Bool {
        meshes[name] != nil
    }
    
    public func materialExists(name: String) -> Bool {
        materials[name] != nil
    }

    public func textureExists(name: String) -> Bool {
        textures[name] != nil
    }

    public func registerMesh(_ name: String, mesh: Mesh) {
        guard let device = device else {
            return
        }
        
        meshes[name] = MetalMesh(device: device, mesh: mesh)
    }
    
    public func registerTexture(_ name: String, url: URL, options: TextureOptions = .init()) {
        guard let device = device else {
            return
        }
        
        guard let texture = try? textureLoader.newTexture(URL: url, options: nil) else {
            return
        }
        
        textures[name] = .init(texture: texture, options: options)
    }

    public func registerMaterial(_ name: String, material: Material) {
        materials[name] = material
    }

    func getShaderIdentifier(for material: String) -> String {
        materials[material]?.options.shader ?? "unknown"
    }

    func createOrGetShader(_ identifier: String, type: String, _ generator: @escaping () -> MTLRenderPipelineState) -> MTLRenderPipelineState {
        let key = "\(identifier)_\(type)"
        
        if let shader = shaders[key] {
            return shader
        }
        
        let shader = generator()
        shaders[key] = shader
        
        return shader
    }
    
    func createOrGetSampler(_ options: TextureOptions) -> MTLSamplerState? {
        if let sampler = samplers[options] {
            return sampler
        }
        
        let descriptor = MTLSamplerDescriptor()
        
        let wrapMode: MTLSamplerAddressMode = switch options.wrapMode {
            case .repeat: .repeat
            case .clampToEdge: .clampToEdge
            case .mirror: .mirrorRepeat
            case .mirrorClampToEdge: .mirrorClampToEdge
        }
        
        let filterMode: MTLSamplerMinMagFilter = switch options.filterMode {
            case .linear: .linear
            case .nearest: .nearest
        }
        
        descriptor.sAddressMode = wrapMode
        descriptor.tAddressMode = wrapMode
        descriptor.rAddressMode = wrapMode
        descriptor.minFilter = filterMode
        descriptor.magFilter = filterMode
        descriptor.maxAnisotropy = options.maxAnisotropy
        
        guard let sampler = device?.makeSamplerState(descriptor: descriptor) else {
            return nil
        }
        
        samplers[options] = sampler
        
        return sampler
    }
}
