import Foundation
import Testing
import simd
@testable import XEngineCore
@testable import XEngineLoader

private final class StubRepository: ResourceRepository {
    var meshes: [String: Mesh] = [:]
    var materials: [String: Material] = [:]
    var textures: [String: URL] = [:]

    func meshExists(name: String) -> Bool { meshes[name] != nil }
    func materialExists(name: String) -> Bool { materials[name] != nil }
    func textureExists(name: String) -> Bool { textures[name] != nil }

    func registerMesh(_ name: String, mesh: Mesh) { meshes[name] = mesh }
    func registerMaterial(_ name: String, material: Material) { materials[name] = material }
    func registerTexture(_ name: String, url: URL, options: TextureOptions) { textures[name] = url }
}

private func write(_ contents: String, as name: String) throws -> URL {
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let url = directory.appending(path: name)
    try contents.write(to: url, atomically: true, encoding: .utf8)

    return url
}

private func vectors(_ data: Data) -> [simd_float3] {
    data.withUnsafeBytes { Array($0.bindMemory(to: simd_float3.self)) }
}

@Suite("ObjectFileLoader")
struct ObjectFileLoaderTests {
    @Test("generates orthogonal tangents rather than reusing the normals")
    func generatesTangents() throws {
        let url = try write("""
        o quad
        v 0 0 0
        v 1 0 0
        v 1 1 0
        vt 0 0
        vt 1 0
        vt 1 1
        vn 0 0 1
        f 1/1/1 2/2/1 3/3/1
        """, as: "quad.obj")

        let repository = StubRepository()
        _ = ObjectFileLoader.load(url, repository: repository)

        let mesh = try #require(repository.meshes.values.first)
        let normals = vectors(mesh.normals)
        let tangents = vectors(mesh.tangents)

        #expect(tangents.count == 3)

        for (normal, tangent) in zip(normals, tangents) {
            #expect(abs(simd_length(tangent) - 1) < 1e-4, "tangent should be unit length")
            #expect(abs(simd_dot(normal, tangent)) < 1e-4, "tangent should be orthogonal to the normal")
            #expect(simd_length(simd_cross(normal, tangent)) > 1e-4, "bitangent must not collapse")
        }

        // The quad's U axis runs along +X, so that is the tangent we expect.
        #expect(simd_length(tangents[0] - simd_float3(1, 0, 0)) < 1e-4)
    }

    @Test("parses faces that omit texture coordinates without misreading the normal")
    func parsesFacesWithoutUVs() throws {
        let url = try write("""
        o tri
        v 0 0 0
        v 1 0 0
        v 0 1 0
        vn 0 0 1
        f 1//1 2//1 3//1
        """, as: "tri.obj")

        let repository = StubRepository()
        _ = ObjectFileLoader.load(url, repository: repository)

        let mesh = try #require(repository.meshes.values.first)

        // Before the fix `1//1` collapsed to (v: 1, vt: 1) and read normals[-1].
        #expect(vectors(mesh.normals).allSatisfy { simd_length($0 - simd_float3(0, 0, 1)) < 1e-4 })
        #expect(vectors(mesh.vertices).count == 3)
    }

    @Test("fan-triangulates quads")
    func triangulatesQuads() throws {
        let url = try write("""
        o quad
        v 0 0 0
        v 1 0 0
        v 1 1 0
        v 0 1 0
        vt 0 0
        vt 1 0
        vt 1 1
        vt 0 1
        vn 0 0 1
        f 1/1/1 2/2/1 3/3/1 4/4/1
        """, as: "quad.obj")

        let repository = StubRepository()
        _ = ObjectFileLoader.load(url, repository: repository)

        let mesh = try #require(repository.meshes.values.first)

        // One quad becomes two triangles, not a flat run of four corners.
        #expect(vectors(mesh.vertices).count == 6)
    }

    @Test("resolves negative (relative) indices")
    func resolvesNegativeIndices() throws {
        let url = try write("""
        o tri
        v 0 0 0
        v 1 0 0
        v 0 1 0
        vt 0 0
        vt 1 0
        vt 0 1
        vn 0 0 1
        f -3/-3/-1 -2/-2/-1 -1/-1/-1
        """, as: "tri.obj")

        let repository = StubRepository()
        _ = ObjectFileLoader.load(url, repository: repository)

        let mesh = try #require(repository.meshes.values.first)
        #expect(vectors(mesh.vertices) == [.init(0, 0, 0), .init(1, 0, 0), .init(0, 1, 0)])
    }

    @Test("survives CRLF line endings")
    func handlesCRLF() throws {
        let url = try write(
            "o tri\r\nv 0 0 0\r\nv 1 0 0\r\nv 0 1 0\r\nvt 0 0\r\nvt 1 0\r\nvt 0 1\r\nvn 0 0 1\r\nf 1/1/1 2/2/1 3/3/1\r\n",
            as: "crlf.obj"
        )

        let repository = StubRepository()
        _ = ObjectFileLoader.load(url, repository: repository)

        let mesh = try #require(repository.meshes.values.first)
        #expect(vectors(mesh.vertices) == [.init(0, 0, 0), .init(1, 0, 0), .init(0, 1, 0)])
    }
}
