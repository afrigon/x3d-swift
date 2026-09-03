public struct ToonMaterialOptions {
    public let albedoColor: Color
    public let albedo: String?
    public let samplingOptions: TextureSamplingOptions

    public var useAlbedoTexture: Bool {
        albedo != nil
    }

    public init(
        albedoColor: Color,
        albedo: String? = nil,
        samplingOptions: TextureSamplingOptions = .init()
    ) {
        self.albedoColor = albedoColor
        self.albedo = albedo
        self.samplingOptions = samplingOptions
    }
}
