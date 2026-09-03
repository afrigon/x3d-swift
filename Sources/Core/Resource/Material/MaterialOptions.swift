public enum MaterialOptions {
    case unlitColor(UnlitColorMaterialOptions)
    case normals(NormalsMaterialOptions)
    case blinnPhong(BlinnPhongMaterialOptions)
    case toon(ToonMaterialOptions)

    public var shader: String {
        switch self {
            case .unlitColor:
                "unlit_color"
            case .blinnPhong:
                "blinn_phong"
            case .toon:
                "toon"
            case .normals:
                "normals"
        }
    }
}
