import Foundation
import simd

/// Fewer vertices for models too detailed for League (a skin model holds at most 65,535): vertices are merged into a
/// neighbor where that changes the shape least (quadric error), never on texture seams or part borders (no cracks),
/// never where a triangle would flip, and preferably between vertices moved by the same bones.
enum Simplify {
    struct Input {
        var positions: [SIMD3<Float>], normals: [SIMD3<Float>], uvs: [SIMD2<Float>]
        var boneIndices: [SIMD4<UInt8>], weights: [SIMD4<Float>]
        var parts: [(name: String, triangles: [SIMD3<Int32>])]
    }

    /// Simplifies to at most `target` vertices.
    static func run(_ input: Input, target: Int) -> SkinnedMesh {
        var tris: [SIMD3<Int32>] = [], triPart: [Int] = []
        for (p, part) in input.parts.enumerated() { tris += part.triangles; triPart += Array(repeating: p, count: part.triangles.count) }
        let n = input.positions.count
        var alive = [Bool](repeating: true, count: tris.count)
        if n <= target { return output(input, tris, triPart, alive) }
        var vTris = [[Int]](repeating: [], count: n)
        for (t, tri) in tris.enumerated() { for k in 0 ..< 3 { vTris[Int(tri[k])].append(t) } }

        // Locked: on an open edge (seams, holes) or shared by two parts.
        var edgeUse: [Int64: Int] = [:]
        func key(_ a: Int32, _ b: Int32) -> Int64 { Int64(min(a, b)) << 32 | Int64(max(a, b)) }
        for tri in tris { for k in 0 ..< 3 { edgeUse[key(tri[k], tri[(k + 1) % 3]), default: 0] += 1 } }
        var locked = [Bool](repeating: false, count: n)
        for (e, c) in edgeUse where c == 1 { locked[Int(e >> 32)] = true; locked[Int(e & 0xFFFF_FFFF)] = true }
        for v in 0 ..< n where Set(vTris[v].map { triPart[$0] }).count > 1 { locked[v] = true }

        // Quadrics (plane errors) per vertex, as 10 doubles.
        typealias Q = [Double]
        var quad = [Q](repeating: Q(repeating: 0, count: 10), count: n)
        for tri in tris {
            let a = SIMD3<Double>(input.positions[Int(tri[0])]), b = SIMD3<Double>(input.positions[Int(tri[1])]), c = SIMD3<Double>(input.positions[Int(tri[2])])
            var nrm = simd_cross(b - a, c - a)
            let len = simd_length(nrm)
            guard len > 1e-12 else { continue }
            nrm /= len
            let d = -simd_dot(nrm, a)
            let q: Q = [nrm.x * nrm.x, nrm.x * nrm.y, nrm.x * nrm.z, nrm.x * d, nrm.y * nrm.y, nrm.y * nrm.z, nrm.y * d, nrm.z * nrm.z, nrm.z * d, d * d]
            for k in 0 ..< 3 { for i in 0 ..< 10 { quad[Int(tri[k])][i] += q[i] * len } }
        }
        func error(_ q: Q, _ p: SIMD3<Float>) -> Double {
            let x = Double(p.x), y = Double(p.y), z = Double(p.z)
            return q[0] * x * x + 2 * q[1] * x * y + 2 * q[2] * x * z + 2 * q[3] * x + q[4] * y * y + 2 * q[5] * y * z
                + 2 * q[6] * y + q[7] * z * z + 2 * q[8] * z + q[9]
        }
        let lo = input.positions.reduce(SIMD3<Float>(repeating: .greatestFiniteMagnitude)) { simd_min($0, $1) }
        let hi = input.positions.reduce(SIMD3<Float>(repeating: -.greatestFiniteMagnitude)) { simd_max($0, $1) }
        let size = Double(simd_length(hi - lo))
        func boneDifference(_ a: Int, _ b: Int) -> Double {
            var wa: [UInt8: Float] = [:], wb: [UInt8: Float] = [:]
            for k in 0 ..< 4 { wa[input.boneIndices[a][k], default: 0] += input.weights[a][k]; wb[input.boneIndices[b][k], default: 0] += input.weights[b][k] }
            var d: Float = 0
            for k in Set(wa.keys).union(wb.keys) { d += abs((wa[k] ?? 0) - (wb[k] ?? 0)) }
            return Double(d)
        }
        func cost(_ u: Int, _ v: Int) -> Double {
            var q = quad[u]
            for i in 0 ..< 10 { q[i] += quad[v][i] }
            return error(q, input.positions[v]) + boneDifference(u, v) * size * size * 0.0004
        }
        func neighbors(_ u: Int) -> Set<Int> {
            var s = Set<Int>()
            for t in vTris[u] where alive[t] { for k in 0 ..< 3 where Int(tris[t][k]) != u { s.insert(Int(tris[t][k])) } }
            return s
        }
        // Would merging u into v flip or crush a triangle?
        func flips(_ u: Int, _ v: Int) -> Bool {
            for t in vTris[u] where alive[t] {
                let tri = tris[t]
                if tri[0] == Int32(v) || tri[1] == Int32(v) || tri[2] == Int32(v) { continue }
                let p = (0 ..< 3).map { input.positions[Int(tri[$0])] }
                let q = (0 ..< 3).map { Int(tri[$0]) == u ? input.positions[v] : p[$0] }
                let before = simd_cross(p[1] - p[0], p[2] - p[0]), after = simd_cross(q[1] - q[0], q[2] - q[0])
                if simd_length(after) < 1e-9 || simd_dot(simd_normalize(before), simd_normalize(after)) < 0.3 { return true }
            }
            return false
        }

        // Candidates in a heap: (cost, u, v, stamp of u).
        var stamp = [Int](repeating: 0, count: n)
        var heap: [(Double, Int, Int, Int)] = []
        func push(_ e: (Double, Int, Int, Int)) {
            heap.append(e)
            var i = heap.count - 1
            while i > 0 { let p = (i - 1) / 2; if heap[p].0 <= heap[i].0 { break }; heap.swapAt(p, i); i = p }
        }
        func pop() -> (Double, Int, Int, Int)? {
            guard !heap.isEmpty else { return nil }
            let top = heap[0]
            heap[0] = heap[heap.count - 1]; heap.removeLast()
            var i = 0
            while true {
                let l = 2 * i + 1, r = l + 1
                var m = i
                if l < heap.count && heap[l].0 < heap[m].0 { m = l }
                if r < heap.count && heap[r].0 < heap[m].0 { m = r }
                if m == i { break }
                heap.swapAt(i, m); i = m
            }
            return top
        }
        func candidate(_ u: Int) {
            guard !locked[u], !vTris[u].isEmpty else { return }
            stamp[u] += 1
            var best: (Double, Int)?
            for v in neighbors(u) where cost(u, v) < best?.0 ?? .infinity { best = (cost(u, v), v) }
            if let best { push((best.0, u, best.1, stamp[u])) }
        }
        var used = Set<Int>()
        for tri in tris { for k in 0 ..< 3 { used.insert(Int(tri[k])) } }
        var count = used.count
        for u in used { candidate(u) }
        var dead = [Bool](repeating: false, count: n)
        while count > target, let (_, u, v, s) = pop() {
            guard !dead[u], !dead[v], s == stamp[u] else { continue }
            if flips(u, v) { stamp[u] += 1; continue }
            for t in vTris[u] where alive[t] {
                if tris[t][0] == Int32(v) || tris[t][1] == Int32(v) || tris[t][2] == Int32(v) { alive[t] = false; continue }
                for k in 0 ..< 3 where tris[t][k] == Int32(u) { tris[t][k] = Int32(v) }
                vTris[v].append(t)
            }
            vTris[u] = []
            dead[u] = true
            count -= 1
            for i in 0 ..< 10 { quad[v][i] += quad[u][i] }
            candidate(v)
            for w in neighbors(v) { candidate(w) }
        }

        return output(input, tris, triPart, alive)
    }

    /// The remaining triangles, vertices renumbered.
    private static func output(_ input: Input, _ tris: [SIMD3<Int32>], _ triPart: [Int], _ alive: [Bool]) -> SkinnedMesh {
        let n = input.positions.count
        var out = SkinnedMesh()
        var newIndex = [Int](repeating: -1, count: n)
        for (p, part) in input.parts.enumerated() {
            let start = out.indices.count
            for (t, tri) in tris.enumerated() where alive[t] && triPart[t] == p {
                for k in 0 ..< 3 {
                    let v = Int(tri[k])
                    if newIndex[v] < 0 {
                        newIndex[v] = out.positions.count
                        out.positions.append(input.positions[v]); out.normals.append(input.normals[v]); out.uvs.append(input.uvs[v])
                        out.boneIndices.append(input.boneIndices[v]); out.weights.append(input.weights[v])
                    }
                    out.indices.append(UInt16(clamping: newIndex[v]))
                }
            }
            out.parts.append(.init(name: part.name, startIndex: start, indexCount: out.indices.count - start))
        }
        return out
    }
}
