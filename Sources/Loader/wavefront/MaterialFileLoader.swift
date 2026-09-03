import Foundation
import XEngineCore
import simd

public struct MaterialFileLoader {
    private enum MaterialFileInstruction {
        case newMaterial(String)
        case ambientColor(simd_float3)
        case diffuseColor(simd_float3)
        case diffuseTexture(URL)
        case specularColor(simd_float3)
        case specularHighlight(Float)
        case opticalDensity(Float)
        case dissolve(Float)
        case illuminationModel(Int)
    }

    /// Statements we knowingly do not support yet. Listed explicitly so the
    /// "unknown instruction" warning stays meaningful instead of spamming on
    /// every PBR-flavoured `.mtl` in the wild.
    private static let ignoredInstructions: Set<Substring> = [
        "Ke", "Tf", "Tr",
        "map_Ka", "map_Ks", "map_Ns", "map_Ke", "map_d", "map_bump", "map_Bump",
        "bump", "disp", "decal", "refl", "norm",
        "Pr", "Pm", "Ps", "Pc", "Pcr", "aniso", "anisor"
    ]

    /// Returns a map of the material names used by `usemtl` statements to the
    /// repository identifiers the corresponding materials were registered under.
    public static func load(
        _ url: URL,
        generator: (MaterialTemplate) -> Material,
        repository: ResourceRepository
    ) -> [String: String] {
        do {
            guard let data = String(data: try Data(contentsOf: url), encoding: .utf8) else {
                print("MTL Loader: \(url.lastPathComponent) is not valid UTF-8.")
                return [:]
            }

            let baseURL = url.deletingLastPathComponent()
            let lines = data.split(whereSeparator: \.isNewline)

            var materials: [String: String] = [:]
            var template: MaterialTemplate?

            // A nested func rather than a closure: it captures the non-escaping
            // `generator` parameter.
            func flush() {
                guard let template, let name = template.name else {
                    return
                }

                // Qualify with the file URL so materials from different .mtl files
                // can share a name. This identifier is what both the existence
                // check and the registration have to agree on.
                let identifier = "\(url.absoluteString):\(name)"
                materials[name] = identifier

                guard !repository.materialExists(name: identifier) else {
                    return
                }

                if let texture = template.diffuseTexture, !repository.textureExists(name: texture.absoluteString) {
                    repository.registerTexture(texture.absoluteString, url: texture, options: .init())
                }

                repository.registerMaterial(identifier, material: generator(template))
            }

            for line in lines {
                guard let instruction = parse(baseURL: baseURL, line: line) else {
                    continue
                }

                switch instruction {
                    case .ambientColor(let color):
                        template?.ambientColor = color
                    case .diffuseColor(let color):
                        template?.diffuseColor = color
                    case .diffuseTexture(let url):
                        template?.diffuseTexture = url
                    case .specularColor(let color):
                        template?.specularColor = color
                    case .specularHighlight(let value):
                        template?.specularHighlight = value
                    case .opticalDensity(let value):
                        template?.opticalDensity = value
                    case .dissolve(let value):
                        template?.dissolve = value
                    case .illuminationModel(let value):
                        template?.illuminationModel = value
                    case .newMaterial(let name):
                        flush()

                        template = MaterialTemplate()
                        template?.name = name
                }
            }

            flush()

            return materials
        } catch {
            print("MTL Loader: failed to read \(url.lastPathComponent): \(error)")
            return [:]
        }
    }

    private static func parse(baseURL: URL, line: Substring) -> MaterialFileInstruction? {
        let line = line.drop(while: \.isWhitespace)

        guard !line.isEmpty, !line.hasPrefix("#") else {
            return nil
        }

        var components: [Substring] = line.split(whereSeparator: \.isWhitespace)

        guard let instruction = components.first else {
            return nil
        }

        components.removeFirst()

        switch instruction {
            case "newmtl":
                guard let name = components.first else {
                    return nil
                }

                return .newMaterial(String(name))
            case "map_Kd":
                guard let path = texturePath(from: components) else {
                    return nil
                }

                return .diffuseTexture(baseURL.appending(path: path))
            case "Ka":
                return color(from: components).map { .ambientColor($0) }
            case "Kd":
                return color(from: components).map { .diffuseColor($0) }
            case "Ks":
                return color(from: components).map { .specularColor($0) }
            case "Ns":
                return components[safe: 0].flatMap(Float.init).map { .specularHighlight($0) }
            case "Ni":
                return components[safe: 0].flatMap(Float.init).map { .opticalDensity($0) }
            case "d":
                return components[safe: 0].flatMap(Float.init).map { .dissolve($0) }
            case "illum":
                return components[safe: 0].flatMap { Int($0, radix: 10) }.map { .illuminationModel($0) }
            default:
                if !ignoredInstructions.contains(instruction) {
                    print("MTL Loader: Unknown instruction: \(instruction)")
                }

                return nil
        }
    }

    private static func color(from components: [Substring]) -> simd_float3? {
        guard let x = components[safe: 0].flatMap(Float.init),
              let y = components[safe: 1].flatMap(Float.init),
              let z = components[safe: 2].flatMap(Float.init) else {
            return nil
        }

        return .init(x, y, z)
    }

    /// `map_*` statements may carry options before the filename (`map_Kd -s 1 1 1 tex.png`),
    /// and the filename itself may contain spaces. Skip leading option flags and their
    /// numeric arguments, then treat whatever remains as the path.
    private static func texturePath(from components: [Substring]) -> String? {
        let path = components
            .drop { $0.hasPrefix("-") || Float($0) != nil }
            .joined(separator: " ")

        return path.isEmpty ? nil : path
    }
}
