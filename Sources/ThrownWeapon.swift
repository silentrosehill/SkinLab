import Foundation
import simd

/// Weapons a champion's spells throw (Gragas's Q barrel and R cask): static models (.scb) shown by the spell effects.
/// With a weapon swap they're replaced, file for file, by the skin's weapon fitted to the same size.
struct ThrownWeapon {
    let meshPath: String
    let texturePath: String
    let original: Data          // the champion's .scb
    let originalTexture: Data

    static let thrown = ["barrel", "cask", "keg", "axe", "spear", "hammer", "boomerang", "shuriken", "dagger", "scissor", "sword"]
    static let notWeapon = ["trail", "glow", "smear", "shadow", "flash", "ring", "splash", "liquid", "puddle", "foam", "bubble", "cone", "cyl"]

    /// The champion's spell-effect models that are its weapon (by name: barrel, cask…), with the texture each is drawn with.
    static func find(in wad: Wad, champion: String, skin: Int) -> [ThrownWeapon] {
        let folder = skin == 0 ? "/skins/base/" : String(format: "/skins/skin%02d/", skin)
        let own = "assets/characters/\(champion.lowercased())\(folder)"
        var found: [String: String] = [:]
        for h in wad.entries.keys {
            guard let d = try? wad.read(h), d.starts(with: Data("PROP".utf8)), let bin = try? BinFile.parse(d) else { continue }
            for o in bin.objects {
                for f in o.fields {
                    f.value.walk { v in
                        guard case .embed = v else { return }
                        var strings: [String] = []
                        v.walk { if case let .string(s) = $0 { strings.append(s) } }
                        for mesh in strings where mesh.lowercased().hasSuffix(".scb") && mesh.lowercased().hasPrefix(own) {
                            let stem = URL(fileURLWithPath: mesh).deletingPathExtension().lastPathComponent.lowercased()
                            // A weapon by its model's name or its emitter's ("barrel").
                            let names = [stem] + strings.filter { !$0.contains("/") }.map { $0.lowercased() }
                            guard found[mesh] == nil, names.contains(where: { n in thrown.contains { n.contains($0) } }),
                                  !notWeapon.contains(where: { stem.contains($0) }) else { continue }
                            // The texture whose name is closest to the model's ("…_Q_Mis.tex" for "…_Q_Mis.scb").
                            let textures = strings.filter { $0.lowercased().hasSuffix(".tex") || $0.lowercased().hasSuffix(".dds") }
                            func shared(_ t: String) -> Int {
                                let a = Array(stem), b = Array(URL(fileURLWithPath: t).deletingPathExtension().lastPathComponent.lowercased())
                                var n = 0
                                while n < min(a.count, b.count) && a[a.count - 1 - n] == b[b.count - 1 - n] { n += 1 }
                                return n
                            }
                            if let tex = textures.max(by: { shared($0) < shared($1) }) { found[mesh] = tex }
                        }
                    }
                }
            }
        }
        return found.compactMap { mesh, tex in
            guard let m = try? wad.read(pathHash(mesh)), let t = try? wad.read(pathHash(tex)) else { return nil }
            return ThrownWeapon(meshPath: mesh, texturePath: tex, original: m, originalTexture: t)
        }.sorted { $0.meshPath < $1.meshPath }
    }

    /// The vertex positions of an .scb.
    static func positions(_ d: Data) -> [SIMD3<Float>] {
        var r = ByteReader(d)
        guard d.count > 200, d.starts(with: Data("r3d2Mesh".utf8)) else { return [] }
        r.pos = 8
        guard let major = try? r.num(UInt16.self), let minor = try? r.num(UInt16.self) else { return [] }
        r.pos = 140
        guard let count = try? r.num(UInt32.self) else { return [] }
        r.pos = 140 + 12 + 24 + (major == 3 && minor == 2 ? 4 : 0)
        var out: [SIMD3<Float>] = []
        for _ in 0 ..< Int(count) {
            guard let x = try? r.float(), let y = try? r.float(), let z = try? r.float() else { break }
            out.append(SIMD3(x, y, z))
        }
        return out
    }

    /// Center, main axes (longest first) and half-lengths along them.
    static func shape(_ points: [SIMD3<Float>]) -> (center: SIMD3<Float>, axes: [SIMD3<Float>], extents: [Float]) {
        let c = points.reduce(SIMD3<Float>(0, 0, 0), +) / Float(max(points.count, 1))
        var m = simd_float3x3(0)
        for p in points { let d = p - c; m += simd_float3x3(columns: (d * d.x, d * d.y, d * d.z)) }
        var axes: [SIMD3<Float>] = []
        var rest = m
        for i in 0 ..< 2 {
            var v = simd_normalize(i == 0 ? SIMD3<Float>(0.3, 0.5, 0.8) : simd_cross(axes[0], SIMD3<Float>(0.6, 0.2, -0.7)))
            for _ in 0 ..< 60 {
                var n = rest * v
                for a in axes { n -= simd_dot(n, a) * a }
                guard simd_length(n) > 1e-9 else { break }
                v = simd_normalize(n)
            }
            axes.append(v)
            let l = simd_dot(v, m * v)
            rest -= l * simd_float3x3(columns: (v * v.x, v * v.y, v * v.z))
        }
        axes.append(simd_normalize(simd_cross(axes[0], axes[1])))
        let extents = axes.map { a in points.map { abs(simd_dot($0 - c, a)) }.max() ?? 0 }
        return (c, axes, extents)
    }

    /// The skin's weapon (model parts) as an .scb in place of this one: same center, its long side along the old model's
    /// long side, twice as long as the old model (weapons are thinner than barrels).
    func replacement(_ mesh: SkinnedMesh, parts: [String]) -> Data? {
        var index: [Int: UInt32] = [:]
        var points: [SIMD3<Float>] = [], tris: [(UInt32, UInt32, UInt32)] = [], uvs: [(SIMD2<Float>, SIMD2<Float>, SIMD2<Float>)] = []
        for part in mesh.parts where parts.contains(part.name) {
            let end = min(mesh.indices.count, part.startIndex + part.indexCount)
            for t in stride(from: part.startIndex, to: end - 2, by: 3) {
                let v = (0 ..< 3).map { Int(mesh.indices[t + $0]) }
                let ids = v.map { i -> UInt32 in
                    if let k = index[i] { return k }
                    points.append(mesh.positions[i])
                    index[i] = UInt32(points.count - 1)
                    return UInt32(points.count - 1)
                }
                tris.append((ids[0], ids[1], ids[2]))
                uvs.append((mesh.uvs[v[0]], mesh.uvs[v[1]], mesh.uvs[v[2]]))
            }
        }
        let old = Self.positions(original)
        guard points.count > 2, old.count > 2 else { return nil }
        let from = Self.shape(points), to = Self.shape(old)
        let scale = from.extents[0] > 0 ? 2 * to.extents[0] / from.extents[0] : 1
        let placed = points.map { p -> SIMD3<Float> in
            let d = p - from.center
            let local = SIMD3(simd_dot(d, from.axes[0]), simd_dot(d, from.axes[1]), simd_dot(d, from.axes[2]))
            return to.center + scale * (local.x * to.axes[0] + local.y * to.axes[1] + local.z * to.axes[2])
        }
        return Self.write(placed, tris, uvs)
    }

    /// Writes an .scb (version 3.2, no vertex colors).
    static func write(_ points: [SIMD3<Float>], _ tris: [(UInt32, UInt32, UInt32)], _ uvs: [(SIMD2<Float>, SIMD2<Float>, SIMD2<Float>)]) -> Data {
        var out = Data("r3d2Mesh".utf8)
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        func f(_ v: Float) { u32(v.bitPattern) }
        u16(3); u16(2)
        out.append(Data(count: 128))                                  // name
        u32(UInt32(points.count)); u32(UInt32(tris.count)); u32(0)    // flags
        let lo = points.reduce(SIMD3<Float>(repeating: .greatestFiniteMagnitude)) { simd_min($0, $1) }
        let hi = points.reduce(SIMD3<Float>(repeating: -.greatestFiniteMagnitude)) { simd_max($0, $1) }
        for v in [lo, hi] { f(v.x); f(v.y); f(v.z) }
        u32(0)                                                        // vertex type: positions only
        for p in points { f(p.x); f(p.y); f(p.z) }
        let c = (lo + hi) / 2
        f(c.x); f(c.y); f(c.z)                                        // central point
        for (t, uv) in zip(tris, uvs) {
            u32(t.0); u32(t.1); u32(t.2)
            out.append(Data(count: 64))                               // material: the effect picks the texture
            f(uv.0.x); f(uv.1.x); f(uv.2.x); f(uv.0.y); f(uv.1.y); f(uv.2.y)
        }
        return out
    }
}
