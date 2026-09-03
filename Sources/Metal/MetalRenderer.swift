import XEngineCore
import MetalKit

class MetalRenderer {
    private(set) var repository: MetalResourceRepository
    private(set) var targetPool: RenderTargetPool

    private var device: MTLDevice
    private var library: MTLLibrary
    private var commandQueue: MTLCommandQueue
    
    private var sceneRenderPassDescriptor: MTLRenderPassDescriptor? = nil
    private var outputRenderPassDescriptor: MTLRenderPassDescriptor? = nil

    private lazy var depthStencilState: MTLDepthStencilState = {
        let descriptor = MTLDepthStencilDescriptor()
        descriptor.isDepthWriteEnabled = true
        descriptor.depthCompareFunction = .less

        guard let depthStencilState = device.makeDepthStencilState(descriptor: descriptor) else {
            fatalError("Failed to create depth-stencil state.")
        }
        
        return depthStencilState
    }()

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let library = try? device.makeDefaultLibrary(bundle: Bundle.module),
              let commandQueue = device.makeCommandQueue() else {
            return nil
        }
        
        self.device = device
        self.library = library
        self.commandQueue = commandQueue
        self.repository = .init(device: device)
        self.targetPool = .init(device: device)
    }
    
    @MainActor
    func setup(with view: MTKView) {
        view.device = device
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.depthStencilPixelFormat = .depth32Float
        
        targetPool.set(.color, descriptor: .init())
        targetPool.set(.normal, descriptor: .init())
        targetPool.set(.depth, descriptor: .init(pixelFormat: .depth32Float))
        targetPool.set(.postSwapA, descriptor: .init())
        targetPool.set(.postSwapB, descriptor: .init())
    }
    
    func resize(width: UInt32, height: UInt32) {
        resizeTextures(width: Int(width), height: Int(height))
    }
    
    private func resizeTextures(width: Int, height: Int) {
        guard width > 0 && height > 0 else {
            return
        }
        
        targetPool.resize(width: Int(width), height: Int(height))

        if let color = targetPool.get(.color),
           let normal = targetPool.get(.normal),
           let depth = targetPool.get(.depth) {
            sceneRenderPassDescriptor = MTLRenderPassDescriptor()
            sceneRenderPassDescriptor?.colorAttachments[0].texture = color
            sceneRenderPassDescriptor?.colorAttachments[0].loadAction = .clear
            sceneRenderPassDescriptor?.colorAttachments[0].storeAction = .store

            sceneRenderPassDescriptor?.colorAttachments[1].texture = normal
            sceneRenderPassDescriptor?.colorAttachments[1].loadAction = .clear
            sceneRenderPassDescriptor?.colorAttachments[1].storeAction = .store
            sceneRenderPassDescriptor?.colorAttachments[1].clearColor = .init(red: 0.5, green: 0.5, blue: 1, alpha: 1)

            sceneRenderPassDescriptor?.depthAttachment.texture = depth
            sceneRenderPassDescriptor?.depthAttachment.loadAction = .clear
            sceneRenderPassDescriptor?.depthAttachment.storeAction = .store
            sceneRenderPassDescriptor?.depthAttachment.clearDepth = 1.0
        }
        
        outputRenderPassDescriptor = MTLRenderPassDescriptor()
        outputRenderPassDescriptor?.colorAttachments[0].loadAction = .clear
        outputRenderPassDescriptor?.colorAttachments[0].storeAction = .store
    }
    
    @MainActor
    func draw(scene: GameScene, globals: Globals, in view: MTKView, debug: DebugOptions = .init()) {
        // resources management load / clean
        // ideas: ref count + periodic purge if above memory quota
        // for the pokemon project all asset should fit into ram without any problem
        
        // TODO: add some rate limiting semaphore thing?? research why I had that in the other project
        
        guard let drawable = view.currentDrawable else {
            return
        }
        
        targetPool.output = drawable.texture
        outputRenderPassDescriptor?.colorAttachments[0].texture = drawable.texture

        guard let camera = scene.mainCamera else {
            return
        }
        
        let clearColor = MTLClearColor(
            red: Double(camera.clearColor.red),
            green: Double(camera.clearColor.green),
            blue: Double(camera.clearColor.blue),
            alpha: Double(camera.clearColor.alpha)
        )
        
        sceneRenderPassDescriptor?.colorAttachments[0].clearColor = clearColor
        outputRenderPassDescriptor?.colorAttachments[0].clearColor = clearColor

        drawFrame(on: drawable) { commandBuffer in
            drawScene(scene: scene, globals: globals, debug: debug, commandBuffer: commandBuffer)
//            let processed = drawPost(effects: camera.postProcessing.effects, globals: globals, commandBuffer: commandBuffer)
            if let color = targetPool.get(.color) {
                drawOutput(from: color, commandBuffer: commandBuffer)
            }
        }
    }
    
    private func drawScene(scene: GameScene, globals: Globals, debug: DebugOptions, commandBuffer: MTLCommandBuffer) {
        guard let camera = scene.mainCamera else {
            return
        }

        guard let descriptor = sceneRenderPassDescriptor,
              let sceneEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }
        
        sceneEncoder.label = "Scene Encoder"

        sceneEncoder.setDepthStencilState(depthStencilState)
        sceneEncoder.setTriangleFillMode(debug.wireframe ? .lines : .fill)
        
        var globals = globals
        
        let lights = scene
            .query(component: Light.self)
            .filter { _ in
                // TODO: filter lights based on distance / other euristics
                
                true
            } + [  // adding default lights so the shaders don't crash
                Light(options: .directional(.init(color: .black, intensity: 0)))
            ]
        
        let directionalLights: [DirectionalLight] = lights
            .compactMap { (light) -> DirectionalLight? in
                guard case let .directional(options) = light.options else {
                    return nil
                }
                
                return .init(
                    direction: simd_normalize(light.transform.rotation.act(.forward)),
                    color: options.color.rgb,
                    intensity: options.intensity
                )
            }
            
        let jobs: [RenderJob] = (scene
            .query(component: MeshRenderer.self)
            .map {
                .basic(
                    mode: repository.materials[$0.material]?.commonOptions.renderingMode ?? .opaque,
                    shader: repository.getShaderIdentifier(for: $0.material),
                    renderer: $0
                )
            } +
        scene
            .query(component: SkinnedMeshRenderer.self)
            .map {
                .skinned(
                    mode: repository.materials[$0.material]?.commonOptions.renderingMode ?? .opaque,
                    shader: repository.getShaderIdentifier(for: $0.material),
                    renderer: $0
                )
            }
        )
        .sorted()
        
        // TODO: filter visible objects
        
        var shaderCache: String? = nil
        var materialCache: String? = nil
        var meshCache: String? = nil

        var pipeline: MTLRenderPipelineState? = nil
        var material: Material? = nil
        var mesh: MetalMesh? = nil

        for job in jobs {
            let currentMaterial = debug.materialOverride ?? job.material
            let currentShader = debug.materialOverride.map {
                repository.getShaderIdentifier(for: $0)
            } ?? job.shader
            let shaderId = "\(currentShader)_\(job.type)"
            
            if shaderCache != shaderId {
                pipeline = repository.createOrGetShader(currentShader, type: job.type) {
                    self.createRenderPipelineState(currentShader, type: job.type)
                }
                
                sceneEncoder.setRenderPipelineState(pipeline!)
                
                shaderCache = shaderId
            }
            
            if materialCache != currentMaterial {
                material = repository.materials[currentMaterial]

                if let material {
                    sceneEncoder.setCullMode(material.commonOptions.cullingMode.metal)
                    sceneEncoder.setFrontFacing(material.commonOptions.frontFacing.metal)
                    sceneEncoder.setDepthBias(material.commonOptions.depthBias ? 0.001 : 0, slopeScale: 1, clamp: 0)

                    switch material.options {
                        case .unlitColor(let m):
                            sceneEncoder.setFragmentBytes([m.color], length: MemoryLayout.size(ofValue: m.color), index: 1)
                        case .toon(let m):
                            let data = ToonData(
                                directionalLightCount: UInt32(directionalLights.count),
                                useAlbedoTexture: m.useAlbedoTexture,
                                albedoColor: m.albedoColor.rgba,
                                eyePosition: camera.transform.position,
                                alphaCutoff: material.commonOptions.renderingMode.alphaCutoff,
                                tiling: m.samplingOptions.tiling,
                                offset: m.samplingOptions.offset
                            )
                            sceneEncoder.setFragmentBytes([data], length: MemoryLayout<ToonData>.stride, index: 1)
                            sceneEncoder.setFragmentBytes(directionalLights, length: MemoryLayout<DirectionalLight>.stride * directionalLights.count, index: 2)
                            
                            if let albedoId = m.albedo,
                               let albedo = repository.textures[albedoId],
                               let sampler = repository.createOrGetSampler(albedo.options) {
                                sceneEncoder.setFragmentTexture(albedo.texture, index: 3)
                                sceneEncoder.setFragmentSamplerState(sampler, index: 4)
                            }
                        case .blinnPhong(let m):
                            let data = BlinnPhongData(
                                directionalLightCount: UInt32(directionalLights.count),
                                useAlbedoTexture: m.useAlbedoTexture,
                                useNormalMap: m.useNormalMap,
                                albedoColor: m.albedoColor.rgba,
                                specularStrength: m.specularStrength,
                                shininess: m.shininess,
                                eyePosition: camera.transform.position,
                                alphaCutoff: material.commonOptions.renderingMode.alphaCutoff,
                                tiling: m.samplingOptions.tiling,
                                offset: m.samplingOptions.offset
                            )
                            sceneEncoder.setFragmentBytes([data], length: MemoryLayout<BlinnPhongData>.stride, index: 1)
                            sceneEncoder.setFragmentBytes(directionalLights, length: MemoryLayout<DirectionalLight>.stride * directionalLights.count, index: 2)
                            
                            if let albedoId = m.albedo,
                               let albedo = repository.textures[albedoId],
                               let sampler = repository.createOrGetSampler(albedo.options) {
                                sceneEncoder.setFragmentTexture(albedo.texture, index: 3)
                                sceneEncoder.setFragmentSamplerState(sampler, index: 4)
                            }
                            
                            if let normalMapId = m.normalMap,
                               let normalMap = repository.textures[normalMapId],
                               let sampler = repository.createOrGetSampler(normalMap.options) {
                                sceneEncoder.setFragmentTexture(normalMap.texture, index: 5)
                                sceneEncoder.setFragmentSamplerState(sampler, index: 6)
                            }
                        case .normals:
                            break
                    }
                }
                
                materialCache = job.material
            }
            
            if meshCache != job.mesh {
                mesh = repository.meshes[job.mesh]
                
                if let mesh {
                    sceneEncoder.setVertexBuffer(mesh.verticesBuffer, index: 1)
                    sceneEncoder.setVertexBuffer(mesh.normalsBuffer, index: 2)
                    sceneEncoder.setVertexBuffer(mesh.tangentsBuffer, index: 3)
                    sceneEncoder.setVertexBuffer(mesh.uv0Buffer, index: 4)
                    
                    if case .skinned(_, _, let renderer) = job {
                        guard let boneIndices = mesh.boneIndicesBuffer else {
                            continue
                        }
                        
                        sceneEncoder.setVertexBuffer(boneIndices, index: 5)
                    }
                    
                    meshCache = job.mesh
                }
            }
            
            if let mesh {
                switch job {
                    case .basic(_, _, let renderer):
                        globals.modelMatrix = renderer.transform.matrix
                        globals.modelViewProjectionMatrix = camera.viewProjectionMatrix * globals.modelMatrix
                        globals.normalMatrix = simd_transpose(simd_inverse(globals.modelMatrix.matrix3x3))
                    case .skinned(_, _, let renderer):
                        globals.modelMatrix = renderer.transform.matrix
                        globals.modelViewProjectionMatrix = camera.viewProjectionMatrix * globals.modelMatrix
                        globals.normalMatrix = simd_transpose(simd_inverse(globals.modelMatrix.matrix3x3))
                        
                        let bones = renderer.parent?
                            .query(component: Bone.self)
                            .compactMap { $0.finalTransform }
                        
                        guard let bones, let boneBuffer = device.makeBuffer(length: MemoryLayout<simd_float4x4>.stride * bones.count) else {
                            break  // TODO: investigate if this crashes when hit, maybe just continue instead
                        }
                        
                        boneBuffer.contents().copyMemory(from: bones, byteCount: MemoryLayout<simd_float4x4>.stride * bones.count)
                        
                        sceneEncoder.setVertexBuffer(boneBuffer, index: 6)
                }

                sceneEncoder.setVertexBytes(
                    [globals],
                    length: MemoryLayout<Globals>.stride,
                    index: 0
                )
                
                sceneEncoder.setFragmentBytes(
                    [globals],
                    length: MemoryLayout<Globals>.stride,
                    index: 0
                )

                sceneEncoder.drawIndexedPrimitives(
                    type: .triangle,
                    indexCount: mesh.indicesCount,
                    indexType: .uint32,
                    indexBuffer: mesh.indicesBuffer,
                    indexBufferOffset: 0
                )
            }
        }
        
        sceneEncoder.endEncoding()
    }
    
//    private func drawPost(
//        effects: [PostProcessingEffect],
//        globals: Globals,
//        commandBuffer: MTLCommandBuffer
//    ) -> MTLTexture {
//        var output: MTLTexture = input
//        var usingA: Bool = true
//        
//        for effect in effects {
//            guard let descriptor = usingA ? postRenderTargetA.renderPassDescriptor : postRenderTargetB.renderPassDescriptor,
//                  let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
//                fatalError("Failed to make render command encoder.")
//            }
//            encoder.label = "Post Processing Encoder \(usingA ? "A" : "B") (\(effect.shader))"
//            
//            guard let target = usingA ? postRenderTargetA.colorTexture : postRenderTargetB.colorTexture else {
//                continue
//            }
//            
//            drawPostLayer(
//                from: output,
//                to: target,
//                effect: effect,
//                postEncoder: encoder,
//                globals: globals
//            )
//            
//            usingA = !usingA
//            output = target
//        }
//        
//        return output
//    }
//    
//    private func drawPostLayer(
//        from input: MTLTexture,
//        to output: MTLTexture,
//        effect: PostProcessingEffect,
//        postEncoder: MTLRenderCommandEncoder,
//        globals: Globals
//    ) {
//        defer {
//            postEncoder.endEncoding()
//        }
//        
//        let pipeline = repository.createOrGetShader(effect.shader, type: "post") {
//            self.createPostRenderPipelineState(effect.shader)
//        }
//        
//        postEncoder.setRenderPipelineState(pipeline)
//        
//        postEncoder.setFragmentTexture(input, index: 0)
//        
//        if effect.needsDepthTexture {
//            postEncoder.setFragmentTexture(sceneRenderTarget.depthTexture, index: 1)
//        }
//        
//        if effect.needsNormalTexture {
//            postEncoder.setFragmentTexture(sceneRenderTarget.normalTexture, index: 2)
//        }
//
//        postEncoder.setFragmentBytes([globals], length: MemoryLayout<Globals>.stride, index: 3)
//
//        switch effect {
//            case .fxaa(let options):
//                postEncoder.setFragmentBytes([options], length: MemoryLayout<FXAAOptions>.stride, index: 4)
//            case .fog(let options):
//                postEncoder.setFragmentBytes([options], length: MemoryLayout<FogOptions>.stride, index: 4)
//            case .ssao:
//                guard let noise = ssaoNoise?.texture else {
//                    return
//                }
//                
//                postEncoder.setFragmentTexture(noise, index: 5)
//            default:
//                break
//        }
//        
//        postEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
//    }
    
    private func drawOutput(from input: MTLTexture, commandBuffer: MTLCommandBuffer) {
        guard let descriptor = outputRenderPassDescriptor,
              let outputEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            fatalError("Failed to make render command encoder.")
        }
        outputEncoder.label = "Output Encoder"
        
        let outputPipeline = repository.createOrGetShader("identity", type: "post") {
            self.createPostRenderPipelineState("identity")
        }
        
        outputEncoder.setRenderPipelineState(outputPipeline)
        
        outputEncoder.setFragmentTexture(input, index: 0)
        outputEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        
        outputEncoder.endEncoding()
    }
    
    private func drawFrame(on output: MTLDrawable, _ block: (MTLCommandBuffer) -> Void) {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            fatalError("Failed to create a command new command buffer.")
        }
        
        block(commandBuffer)

        commandBuffer.present(output)
        commandBuffer.commit()
    }
    
    private func createRenderPipelineState(_ shader: String, type: String) -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "\(shader) Render Pipeline"
        
        descriptor.vertexFunction = library.makeFunction(name: "vertex_\(type)")
        descriptor.fragmentFunction = library.makeFunction(name: "fragment_\(shader)")

        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        descriptor.colorAttachments[1].pixelFormat = .bgra8Unorm_srgb
        descriptor.depthAttachmentPixelFormat = .depth32Float
        descriptor.stencilAttachmentPixelFormat = .invalid
        
        do {
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            fatalError(error.localizedDescription)
        }
    }
    
    private func createPostRenderPipelineState(_ shader: String) -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Post Processing (\(shader)) Render Pipeline"
        
        descriptor.vertexFunction = library.makeFunction(name: "vertex_quad")
        descriptor.fragmentFunction = library.makeFunction(name: "fragment_post_\(shader)")

        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        descriptor.depthAttachmentPixelFormat = .invalid
        descriptor.stencilAttachmentPixelFormat = .invalid
        
        do {
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            fatalError(error.localizedDescription)
        }
    }
}
