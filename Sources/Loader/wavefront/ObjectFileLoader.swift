import Foundation
import XEngineCore
import simd

public struct ObjectFileLoader {
    /// One `v/vt/vn` corner of a face. Indices are raw OBJ values: 1-based, with
    /// negatives counting back from the end of the list parsed so far, and 0 meaning
    /// the field was absent.
    private struct FaceCorner {
        let vertex: Int
        let uv: Int
        let normal: Int
    }

    private enum ObjectFileInstruction {
        case object(String)
        case vertex(simd_float3)
        case normal(simd_float3)
        case uv(simd_float2)
        case face([FaceCorner])
        case line([(simd_float3, simd_float2)])
        case material(String)
        case useMaterial(String)
        case group(String)
        case smoothGroup(Int)
    }

    public static func load(
        _ url: URL,
        repository: ResourceRepository,
        materialGenerator: ((MaterialTemplate) -> Material)? = nil
    ) -> GameObject? {
        // for the v1 of this loader we assume a triagulated model with UV and normal information.

        do {
            guard let data = String(data: try Data(contentsOf: url), encoding: .utf8) else {
                return nil
            }

            let lines = data.split(whereSeparator: \.isNewline)

            let container = GameObject()
            container.name = url.absoluteString

            var currentObject: GameObject?
            var currentMaterial: String?
            var meshIndex = 0

            var materials = [String: String]()

            var vertices: [simd_float3] = []
            var normals: [simd_float3] = []
            var uvs: [simd_float2] = []
            var indices: [FaceCorner] = []

            let closeMesh = {
                defer {
                    meshIndex += 1
                    indices = []
                }

                guard !indices.isEmpty else {
                    return
                }

                let meshIdentifier = "\(url.absoluteString):\(meshIndex)"

                if !repository.meshExists(name: meshIdentifier) {
                    guard let mesh = createMesh(
                        vertices: vertices,
                        normals: normals,
                        uvs: uvs,
                        faces: indices
                    ) else {
                        print("OBJ Loader: skipping malformed mesh \(meshIdentifier).")
                        return
                    }

                    repository.registerMesh(meshIdentifier, mesh: mesh)
                }

                currentObject?.addComponent(component: MeshRenderer(
                    mesh: meshIdentifier,
                    material: currentMaterial ?? "default"
                ))
            }

            for line in lines {
                let instruction = parse(line: line)

                switch instruction {
                    case .material(let material):
                        guard let materialGenerator else {
                            continue
                        }

                        let url = url.deletingLastPathComponent().appending(path: material)
                        materials = MaterialFileLoader.load(url, generator: materialGenerator, repository: repository)
                    case .useMaterial(let material):
                        closeMesh()

                        currentMaterial = materials[material]
                    case .vertex(let vertex):
                        vertices.append(vertex)
                    case .normal(let normal):
                        normals.append(normal)
                    case .uv(let uv):
                        uvs.append(uv)
                    case .face(let face):
                        // Fan-triangulate. Correct for convex faces, and a no-op for
                        // faces that are already triangles.
                        guard face.count >= 3 else {
                            continue
                        }

                        for corner in 1..<(face.count - 1) {
                            indices.append(contentsOf: [face[0], face[corner], face[corner + 1]])
                        }
                    case .object(let name):
                        if let currentObject {
                            closeMesh()

                            container.addChild(currentObject)
                        }

                        currentObject = GameObject()
                        currentObject?.name = "\(url.absoluteString):\(name)"
                    default:
                        continue
                }
            }

            if let currentObject {
                closeMesh()

                container.addChild(currentObject)
            }

            return container
        } catch {
            return nil
        }
    }

    private static func parse(line: Substring) -> ObjectFileInstruction? {
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
            case "o":
                guard let name = components.first else {
                    return nil
                }

                return .object(String(name))
            case "v":
                guard let x = components[safe: 0].flatMap(Float.init),
                      let y = components[safe: 1].flatMap(Float.init),
                      let z = components[safe: 2].flatMap(Float.init) else {
                          return nil
                      }

                return .vertex(.init(x, y, z))
            case "vn":
                guard let x = components[safe: 0].flatMap(Float.init),
                      let y = components[safe: 1].flatMap(Float.init),
                      let z = components[safe: 2].flatMap(Float.init) else {
                          return nil
                      }

                return .normal(.init(x, y, z))
            case "vt":
                guard let x = components[safe: 0].flatMap(Float.init),
                      let y = components[safe: 1].flatMap(Float.init) else {
                          return nil
                      }

                return .uv(.init(x, y))
            case "f":
                let points: [FaceCorner] = components.map { point in
                    // Keep empty fields so `1//3` parses as (v: 1, vt: absent, vn: 3)
                    // rather than collapsing to (v: 1, vt: 3). 0 means absent: OBJ
                    // indices are 1-based, with negatives counting back from the end.
                    let fields = point.split(separator: "/", omittingEmptySubsequences: false)

                    return FaceCorner(
                        vertex: fields[safe: 0].flatMap { Int($0) } ?? 0,
                        uv: fields[safe: 1].flatMap { Int($0) } ?? 0,
                        normal: fields[safe: 2].flatMap { Int($0) } ?? 0
                    )
                }

                return .face(points)
            case "l":
                return nil  // ignored for now.
            case "mtllib":
                guard let value = components.first else {
                    return nil
                }

                return .material(String(value))
            case "usemtl":
                guard let value = components.first else {
                    return nil
                }

                return .useMaterial(String(value))
            case "g":
                return nil  // ignored for now.
            case "s":
                return nil  // ignored for now.
            default:
                print("OBJ Loader: Unknown instruction: \(instruction)")

                return nil
        }
    }

    private static func createMesh(
        vertices: [simd_float3],
        normals: [simd_float3],
        uvs: [simd_float2],
        faces: [FaceCorner]
    ) -> Mesh? {
        var v = [simd_float3]()
        var n = [simd_float3]()
        var t = [simd_float3]()
        var u = [simd_float2]()
        var indices = [UInt32]()

        for corner in faces {
            // A face corner without a position is unrecoverable; drop the mesh rather
            // than emit a triangle list that is silently one corner short.
            guard let vertexIndex = resolve(corner.vertex, count: vertices.count) else {
                return nil
            }

            v.append(vertices[vertexIndex])
            n.append(resolve(corner.normal, count: normals.count).map { normals[$0] } ?? .zero)

            // OBJ texture coordinates are bottom-up, Metal samples top-down.
            let uv = resolve(corner.uv, count: uvs.count).map { uvs[$0] } ?? .zero
            u.append(.init(uv.x, 1 - uv.y))

            indices.append(UInt32(indices.count))
        }

        guard v.count % 3 == 0 else {
            return nil
        }

        // The triangle list is unindexed, so every triangle owns its three corners and
        // per-face tangents need no averaging across shared vertices.
        for i in stride(from: 0, to: v.count, by: 3) {
            let edge1 = v[i + 1] - v[i]
            let edge2 = v[i + 2] - v[i]

            let deltaUV1 = u[i + 1] - u[i]
            let deltaUV2 = u[i + 2] - u[i]

            // Fill in a geometric normal when the file carried none.
            for corner in i..<(i + 3) where n[corner] == .zero {
                n[corner] = normalized(simd_cross(edge1, edge2)) ?? .init(0, 1, 0)
            }

            let determinant = deltaUV1.x * deltaUV2.y - deltaUV1.y * deltaUV2.x
            let tangent = normalized((edge1 * deltaUV2.y - edge2 * deltaUV1.y) * (1 / determinant))

            // Degenerate UVs (or a degenerate triangle) leave no usable tangent
            // direction. Pick an arbitrary one orthogonal to the normal so the TBN
            // basis in the shader stays well-formed instead of collapsing.
            let fallback = { orthogonal(to: n[i]) }

            t.append(contentsOf: repeatElement(
                determinant.isFinite && abs(determinant) > 1e-12 ? (tangent ?? fallback()) : fallback(),
                count: 3
            ))
        }

        return Mesh(
            vertices: v.withUnsafeBufferPointer { Data(buffer: $0) },
            indices: indices.withUnsafeBufferPointer { Data(buffer: $0) },
            normals: n.withUnsafeBufferPointer { Data(buffer: $0) },
            tangents: t.withUnsafeBufferPointer { Data(buffer: $0) },
            uv: u.withUnsafeBufferPointer { Data(buffer: $0) },
            boneIndices: nil
        )
    }

    /// Maps a 1-based OBJ index (negative values count back from the end of the list
    /// parsed so far, 0 means the field was absent) onto a 0-based array index.
    private static func resolve(_ index: Int, count: Int) -> Int? {
        let resolved = index < 0 ? count + index : index - 1

        return (0..<count).contains(resolved) ? resolved : nil
    }

    private static func normalized(_ vector: simd_float3) -> simd_float3? {
        let length = simd_length(vector)

        guard length.isFinite, length > 1e-12 else {
            return nil
        }

        return vector / length
    }

    private static func orthogonal(to normal: simd_float3) -> simd_float3 {
        // Cross with whichever axis the normal is least aligned with, so the result
        // is never near-zero.
        let axis: simd_float3 = abs(normal.x) < 0.9 ? .init(1, 0, 0) : .init(0, 1, 0)

        return normalized(simd_cross(axis, normal)) ?? .init(1, 0, 0)
    }
}
