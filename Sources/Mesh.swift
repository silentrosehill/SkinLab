import Foundation
import simd

/// A champion model (.skn): one vertex buffer shared by named parts ("submeshes").
struct SkinnedMesh {
    struct Part {
        let name: String
        let startIndex: Int
        let indexCount: Int
    }

    var parts: [Part] = []
    var indices: [UInt16] = []
    var positions: [SIMD3<Float>] = []
    var normals: [SIMD3<Float>] = []
    var uvs: [SIMD2<Float>] = []
    var boneIndices: [SIMD4<UInt8>] = []
    var weights: [SIMD4<Float>] = []
    var trailingBytes = 0

    static func parse(_ data: Data) throws -> SkinnedMesh {
        var r = ByteReader(data)
        guard try r.num(UInt32.self) == 0x0011_2233 else { throw FormatError("Not a .skn model") }
        let major: UInt16 = try r.num()
        _ = try r.num(UInt16.self)
        var mesh = SkinnedMesh()

        var ranges: [(String, Int, Int)] = []
        if major > 0 {
            let count = Int(try r.num(UInt32.self))
            for _ in 0 ..< count {
                let nameBytes = try r.bytes(64)
                let name = String(decoding: nameBytes.prefix { $0 != 0 }, as: UTF8.self)
                _ = try r.num(UInt32.self)      // first vertex
                _ = try r.num(UInt32.self)      // vertex count
                let startIndex = Int(try r.num(UInt32.self))
                let indexCount = Int(try r.num(UInt32.self))
                ranges.append((name, startIndex, indexCount))
            }
        }
        if major >= 4 { _ = try r.num(UInt32.self) }   // flags
        let indexCount = Int(try r.num(UInt32.self))
        let vertexCount = Int(try r.num(UInt32.self))
        var vertexSize = 52
        if major >= 4 {
            vertexSize = Int(try r.num(UInt32.self))
            _ = try r.num(UInt32.self)                  // vertex type
            try r.skip(40)                              // bounding box + sphere
        }
        guard vertexSize >= 52 else { throw FormatError("Unsupported vertex layout") }

        mesh.indices.reserveCapacity(indexCount)
        for _ in 0 ..< indexCount { mesh.indices.append(try r.num()) }

        for _ in 0 ..< vertexCount {
            let start = r.pos
            mesh.positions.append(SIMD3(try r.float(), try r.float(), try r.float()))
            mesh.boneIndices.append(SIMD4(try r.num(), try r.num(), try r.num(), try r.num()))
            mesh.weights.append(SIMD4(try r.float(), try r.float(), try r.float(), try r.float()))
            mesh.normals.append(SIMD3(try r.float(), try r.float(), try r.float()))
            mesh.uvs.append(SIMD2(try r.float(), try r.float()))
            r.pos = start + vertexSize
        }

        if ranges.isEmpty { ranges = [("Body", 0, indexCount)] }
        mesh.parts = ranges.map { Part(name: $0.0, startIndex: $0.1, indexCount: $0.2) }
        mesh.trailingBytes = r.remaining
        if let maxIndex = mesh.indices.max(), Int(maxIndex) >= vertexCount {
            throw FormatError("Model indices are out of range")
        }
        return mesh
    }

    /// The same model without vertices no part uses (left-out props), indices renumbered.
    func compacted() -> SkinnedMesh {
        var used = [Int](repeating: -1, count: positions.count)
        var out = SkinnedMesh()
        out.trailingBytes = trailingBytes
        for part in parts {
            let start = out.indices.count
            for i in indices[part.startIndex ..< min(indices.count, part.startIndex + part.indexCount)] {
                let v = Int(i)
                if used[v] < 0 {
                    used[v] = out.positions.count
                    out.positions.append(positions[v]); out.normals.append(normals[v]); out.uvs.append(uvs[v])
                    out.boneIndices.append(boneIndices[v]); out.weights.append(weights[v])
                }
                out.indices.append(UInt16(used[v]))
            }
            out.parts.append(.init(name: part.name, startIndex: start, indexCount: out.indices.count - start))
        }
        return out
    }

    /// Writes a .skn (version 4.1, basic vertices). Parts must index this mesh's vertices.
    func serialized() -> Data {
        var w = BinWriter()
        w.num(UInt32(0x0011_2233))
        w.num(UInt16(4)); w.num(UInt16(1))
        w.num(UInt32(parts.count))
        for part in parts {
            var name = Array(part.name.utf8.prefix(63))
            name += [UInt8](repeating: 0, count: 64 - name.count)
            w.out.append(contentsOf: name)
            let idx = indices[part.startIndex ..< part.startIndex + part.indexCount]
            let lo = Int(idx.min() ?? 0), hi = Int(idx.max() ?? 0)
            w.num(UInt32(lo)); w.num(UInt32(hi - lo + 1))
            w.num(UInt32(part.startIndex)); w.num(UInt32(part.indexCount))
        }
        w.num(UInt32(0))                                    // flags
        w.num(UInt32(indices.count)); w.num(UInt32(positions.count))
        w.num(UInt32(52)); w.num(UInt32(0))                 // vertex size, basic vertex type
        let lo = positions.reduce(SIMD3<Float>(repeating: .greatestFiniteMagnitude)) { simd_min($0, $1) }
        let hi = positions.reduce(SIMD3<Float>(repeating: -.greatestFiniteMagnitude)) { simd_max($0, $1) }
        let center = (lo + hi) / 2
        let radius = positions.reduce(Float(0)) { max($0, simd_distance($1, center)) }
        func f(_ v: Float) { w.num(v.bitPattern) }
        [lo.x, lo.y, lo.z, hi.x, hi.y, hi.z, center.x, center.y, center.z, radius].forEach(f)
        indices.forEach { w.num($0) }
        for v in positions.indices {
            f(positions[v].x); f(positions[v].y); f(positions[v].z)
            for k in 0 ..< 4 { w.num(boneIndices[v][k]) }
            for k in 0 ..< 4 { f(weights[v][k]) }
            f(normals[v].x); f(normals[v].y); f(normals[v].z)
            f(uvs[v].x); f(uvs[v].y)
        }
        // trailing marker some readers expect
        w.out.append(Data(count: 12))
        return w.out
    }
}
