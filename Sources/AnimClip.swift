import Foundation
import simd

/// One joint's transform relative to its parent.
struct JointPose: Equatable {
    var rotation: simd_quatf
    var translation: SIMD3<Float>
    var scale: SIMD3<Float>

    var matrix: simd_float4x4 { Skeleton.trs(translation, rotation, scale) }
}

/// A whole animation, sampled frame by frame: each animated joint (by ELF name hash) has one pose per frame.
struct AnimClip {
    var fps: Float
    var frameCount: Int
    var tracks: [UInt32: [JointPose]]

    var duration: Float { Float(max(frameCount - 1, 0)) / fps }

    // MARK: Reading

    static func decode(_ data: Data) throws -> AnimClip {
        guard data.count > 12 else { throw FormatError("Animation is too short") }
        let d = [UInt8](data)
        let magic = String(decoding: d[0 ..< 8], as: UTF8.self)
        let version = u32(d, 8)
        switch (magic, version) {
        case ("r3d2canm", _): return try compressed(d)
        case ("r3d2anmd", 5): return try uncompressed(d, v5: true)
        case ("r3d2anmd", 4): return try uncompressed(d, v5: false)
        case ("r3d2anmd", 3): return try legacy(d)
        default: throw FormatError("Unknown animation format \(magic) v\(version)")
        }
    }

    private static func u16(_ d: [UInt8], _ o: Int) -> UInt16 { UInt16(d[o]) | UInt16(d[o + 1]) << 8 }
    private static func u32(_ d: [UInt8], _ o: Int) -> UInt32 { UInt32(u16(d, o)) | UInt32(u16(d, o + 2)) << 16 }
    private static func i32(_ d: [UInt8], _ o: Int) -> Int { Int(Int32(bitPattern: u32(d, o))) }
    private static func f32(_ d: [UInt8], _ o: Int) -> Float { Float(bitPattern: u32(d, o)) }
    private static func vec(_ d: [UInt8], _ o: Int) -> SIMD3<Float> { SIMD3(f32(d, o), f32(d, o + 4), f32(d, o + 8)) }

    /// 48-bit "smallest three" rotation.
    static func unpackQuat(_ a: UInt16, _ b: UInt16, _ c: UInt16) -> simd_quatf {
        let bits = UInt64(a) | UInt64(b) << 16 | UInt64(c) << 32
        let maxIndex = Int(bits >> 45 & 3)
        let k = Float(2.0.squareRoot()), h = 1 / k
        let va = Float(bits >> 30 & 0x7FFF) / 32767 * k - h
        let vb = Float(bits >> 15 & 0x7FFF) / 32767 * k - h
        let vc = Float(bits & 0x7FFF) / 32767 * k - h
        let dd = max(0, 1 - (va * va + vb * vb + vc * vc)).squareRoot()
        let v: SIMD4<Float>
        switch maxIndex {
        case 0: v = SIMD4(dd, va, vb, vc)
        case 1: v = SIMD4(va, dd, vb, vc)
        case 2: v = SIMD4(va, vb, dd, vc)
        default: v = SIMD4(va, vb, vc, dd)
        }
        return simd_normalize(simd_quatf(vector: v))
    }

    static func packQuat(_ q: simd_quatf) -> [UInt8] {
        var v = simd_normalize(q).vector
        let a = simd_abs(v)
        var maxIndex = 3
        if a.x >= a.w && a.x >= a.y && a.x >= a.z { maxIndex = 0 }
        else if a.y >= a.w && a.y >= a.x && a.y >= a.z { maxIndex = 1 }
        else if a.z >= a.w && a.z >= a.x && a.z >= a.y { maxIndex = 2 }
        if v[maxIndex] < 0 { v = -v }
        var bits = UInt64(maxIndex) << 45
        var slot = 0
        for i in 0 ..< 4 where i != maxIndex {
            let c = UInt64(min(max((32767.0 / 2.0 * (Double(2.0.squareRoot()) * Double(v[i]) + 1.0)).rounded(), 0), 32767))
            bits |= (c & 0x7FFF) << UInt64(15 * (2 - slot))
            slot += 1
        }
        return (0 ..< 6).map { UInt8((bits >> UInt64(8 * $0)) & 0xFF) }
    }

    private static func uncompressed(_ d: [UInt8], v5: Bool) throws -> AnimClip {
        let trackCount = i32(d, 28), frameCount = i32(d, 32)
        let frameDuration = f32(d, 36)
        let hashesOff = i32(d, 40) + 12, vecOff = i32(d, 52) + 12, quatOff = i32(d, 56) + 12, framesOff = i32(d, 60) + 12
        guard frameDuration > 0, trackCount > 0, frameCount > 0 else { throw FormatError("Empty animation") }
        let vecCount = (quatOff - vecOff) / 12
        let vectors = (0 ..< vecCount).map { vec(d, vecOff + $0 * 12) }
        var quats: [simd_quatf] = []
        if v5 {
            let n = (hashesOff - quatOff) / 6
            for i in 0 ..< n {
                let o = quatOff + i * 6
                quats.append(unpackQuat(u16(d, o), u16(d, o + 2), u16(d, o + 4)))
            }
        } else {
            let n = (framesOff - quatOff) / 16
            for i in 0 ..< n {
                let o = quatOff + i * 16
                quats.append(simd_normalize(simd_quatf(ix: f32(d, o), iy: f32(d, o + 4), iz: f32(d, o + 8), r: f32(d, o + 12))))
            }
        }
        let hashes: [UInt32] = v5 ? (0 ..< trackCount).map { u32(d, hashesOff + $0 * 4) } : []
        var tracks: [UInt32: [JointPose]] = [:]
        let frameSize = v5 ? 6 : 12
        guard framesOff + frameCount * trackCount * frameSize <= d.count else { throw FormatError("Animation is truncated") }
        for f in 0 ..< frameCount {
            for t in 0 ..< trackCount {
                let o = framesOff + (f * trackCount + t) * frameSize
                let hash = v5 ? hashes[t] : u32(d, o)
                let base = v5 ? o : o + 4
                let ti = Int(u16(d, base)), si = Int(u16(d, base + 2)), ri = Int(u16(d, base + 4))
                guard ti < vectors.count, si < vectors.count, ri < quats.count else { continue }
                tracks[hash, default: []].append(JointPose(rotation: quats[ri], translation: vectors[ti], scale: vectors[si]))
            }
        }
        return AnimClip(fps: 1 / frameDuration, frameCount: frameCount, tracks: tracks.filter { $0.value.count == frameCount })
    }

    private static func legacy(_ d: [UInt8]) throws -> AnimClip {
        let trackCount = i32(d, 16), frameCount = i32(d, 20), fps = Float(i32(d, 24))
        var o = 28
        var tracks: [UInt32: [JointPose]] = [:]
        for _ in 0 ..< trackCount {
            guard o + 36 + frameCount * 28 <= d.count else { throw FormatError("Animation is truncated") }
            let name = String(decoding: d[o ..< o + 32].prefix { $0 != 0 }, as: UTF8.self)
            o += 36
            var poses: [JointPose] = []
            for _ in 0 ..< frameCount {
                let q = simd_normalize(simd_quatf(ix: f32(d, o), iy: f32(d, o + 4), iz: f32(d, o + 8), r: f32(d, o + 12)))
                poses.append(JointPose(rotation: q, translation: vec(d, o + 16), scale: SIMD3(repeating: 1)))
                o += 28
            }
            tracks[Skeleton.elf(name)] = poses
        }
        return AnimClip(fps: max(fps, 1), frameCount: frameCount, tracks: tracks)
    }

    /// Compressed: per joint, separate keyframe streams for rotation / translation / scale, played as Catmull-Rom curves.
    private static func compressed(_ d: [UInt8]) throws -> AnimClip {
        let flags = u32(d, 20)
        let jointCount = i32(d, 24), frameCount = i32(d, 28)
        let duration = f32(d, 36), fps = f32(d, 40)
        let tMin = vec(d, 68), tMax = vec(d, 80), sMin = vec(d, 92), sMax = vec(d, 104)
        let framesOff = i32(d, 116) + 12, hashesOff = i32(d, 124) + 12
        guard duration > 0, fps > 0, framesOff + frameCount * 10 <= d.count else { throw FormatError("Animation is truncated") }
        let hashes = (0 ..< jointCount).map { u32(d, hashesOff + $0 * 4) }
        let parametrized = flags & 4 != 0

        // Keys per joint and kind, in time order (0 = rotation, 1 = translation, 2 = scale).
        var keys = [[[(time: Float, value: SIMD4<Float>)]]](repeating: [[], [], []], count: jointCount)
        for f in 0 ..< frameCount {
            let o = framesOff + f * 10
            let time = Float(u16(d, o))
            let jt = u16(d, o + 2)
            let joint = Int(jt & 0x3FFF), kind = Int(jt >> 14)
            guard joint < jointCount, kind < 3 else { continue }
            let a = u16(d, o + 4), b = u16(d, o + 6), c = u16(d, o + 8)
            let value: SIMD4<Float>
            if kind == 0 {
                value = unpackQuat(a, b, c).vector
            } else {
                let (lo, hi) = kind == 1 ? (tMin, tMax) : (sMin, sMax)
                let v = SIMD3(Float(a), Float(b), Float(c)) / 65535 * (hi - lo) + lo
                value = SIMD4(v, 0)
            }
            keys[joint][kind].append((time, value))
        }

        func sample(_ k: [(time: Float, value: SIMD4<Float>)], _ t: Float, quat: Bool) -> SIMD4<Float>? {
            guard !k.isEmpty else { return nil }
            if k.count == 1 || t <= k[0].time { return k[0].value }
            if t >= k[k.count - 1].time { return k[k.count - 1].value }
            var i = 0
            while i + 1 < k.count && k[i + 1].time <= t { i += 1 }
            let p1 = k[i], p2 = k[min(i + 1, k.count - 1)]
            let p0 = k[max(i - 1, 0)], p3 = k[min(i + 2, k.count - 1)]
            var v0 = p0.value, v1 = p1.value, v2 = p2.value, v3 = p3.value
            if quat {   // keep all four on the same side as p1 (shortest path)
                if simd_dot(v0, v1) < 0 { v0 = -v0 }
                if simd_dot(v2, v1) < 0 { v2 = -v2 }
                if simd_dot(v3, v2) < 0 { v3 = -v3 }
            }
            let span = p2.time - p1.time
            let amount = span > 0 ? (t - p1.time) / span : 0
            var easeIn: Float = 0.5, easeOut: Float = 0.5
            if parametrized {
                easeIn = span / (p2.time - p0.time + 0.000001)
                easeOut = span / (p3.time - p1.time + 0.000001)
            }
            let m0 = (((2 - amount) * amount) - 1) * (amount * easeIn)
            let m1 = ((((2 - easeOut) * amount) + (easeOut - 3)) * (amount * amount)) + 1
            let m2 = ((((3 - easeIn * 2) + ((easeIn - 2) * amount)) * amount) + easeIn) * amount
            let m3 = ((amount - 1) * amount) * (amount * easeOut)
            let r = m0 * v0 + m1 * v1 + m2 * v2 + m3 * v3
            return quat ? simd_normalize(r) : r
        }

        let n = max(2, Int((duration * fps).rounded()) + 1)
        var tracks: [UInt32: [JointPose]] = [:]
        for j in 0 ..< jointCount {
            var poses: [JointPose] = []
            for f in 0 ..< n {
                let t = min(Float(f) / fps, duration) / duration * 65535
                let r = sample(keys[j][0], t, quat: true).map { simd_quatf(vector: $0) } ?? simd_quatf(angle: 0, axis: SIMD3(0, 1, 0))
                let tr = sample(keys[j][1], t, quat: false).map { SIMD3($0.x, $0.y, $0.z) } ?? .zero
                let sc = sample(keys[j][2], t, quat: false).map { SIMD3($0.x, $0.y, $0.z) } ?? SIMD3(repeating: 1)
                poses.append(JointPose(rotation: r, translation: tr, scale: sc))
            }
            tracks[hashes[j]] = poses
        }
        return AnimClip(fps: fps, frameCount: n, tracks: tracks)
    }

    // MARK: Writing (uncompressed v5, like the game's own)

    func encoded() -> Data {
        let hashes = tracks.keys.sorted()
        var vectors: [SIMD3<Float>] = []
        var vectorIndex: [SIMD3<Float>: Int] = [:]
        var quats: [[UInt8]] = []
        var quatIndex: [[UInt8]: Int] = [:]
        func vi(_ v: SIMD3<Float>) -> UInt16 {
            if let i = vectorIndex[v] { return UInt16(i) }
            vectors.append(v)
            vectorIndex[v] = vectors.count - 1
            return UInt16(vectors.count - 1)
        }
        func qi(_ q: simd_quatf) -> UInt16 {
            let p = AnimClip.packQuat(q)
            if let i = quatIndex[p] { return UInt16(i) }
            quats.append(p)
            quatIndex[p] = quats.count - 1
            return UInt16(quats.count - 1)
        }
        var frames: [UInt8] = []
        for f in 0 ..< frameCount {
            for h in hashes {
                let p = tracks[h]![min(f, tracks[h]!.count - 1)]
                for v in [vi(p.translation), vi(p.scale), qi(p.rotation)] { frames += [UInt8(v & 0xFF), UInt8(v >> 8)] }
            }
        }
        var out = [UInt8](repeating: 0, count: 76)
        func put32(_ o: Int, _ v: UInt32) { for i in 0 ..< 4 { out[o + i] = UInt8((v >> (8 * UInt32(i))) & 0xFF) } }
        out.replaceSubrange(0 ..< 8, with: Array("r3d2anmd".utf8))
        put32(8, 5)
        let vecOff = 64, quatOff = vecOff + vectors.count * 12, hashesOff = quatOff + quats.count * 6, framesOff = hashesOff + hashes.count * 4
        put32(28, UInt32(hashes.count)); put32(32, UInt32(frameCount)); put32(36, (1 / fps).bitPattern)
        put32(40, UInt32(hashesOff)); put32(52, UInt32(vecOff)); put32(56, UInt32(quatOff)); put32(60, UInt32(framesOff))
        for v in vectors { for c in [v.x, v.y, v.z] { let b = c.bitPattern; out += (0 ..< 4).map { UInt8((b >> (8 * UInt32($0))) & 0xFF) } } }
        for q in quats { out += q }
        for h in hashes { out += (0 ..< 4).map { UInt8((h >> (8 * UInt32($0))) & 0xFF) } }
        out += frames
        put32(12, UInt32(out.count - 12))
        return Data(out)
    }
}

// MARK: - Posing a skeleton

extension Skeleton {
    /// Each joint's rest pose relative to its parent, as stored in the file.
    func restPoses(_ file: Data) -> [JointPose] {
        let d = [UInt8](file)
        func f(_ o: Int) -> Float {
            Float(bitPattern: UInt32(d[o]) | UInt32(d[o + 1]) << 8 | UInt32(d[o + 2]) << 16 | UInt32(d[o + 3]) << 24)
        }
        return joints.map { j in
            guard j.record >= 0, j.record + 100 <= d.count else {
                return JointPose(rotation: simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)), translation: j.local, scale: SIMD3(repeating: 1))
            }
            let o = j.record + 16
            return JointPose(rotation: simd_normalize(simd_quatf(ix: f(o + 24), iy: f(o + 28), iz: f(o + 32), r: f(o + 36))),
                             translation: j.local, scale: SIMD3(f(o + 12), f(o + 16), f(o + 20)))
        }
    }

    /// Joint → model space for given local poses (parents are resolved first).
    func globals(_ local: [JointPose]) -> [simd_float4x4] {
        var g = [simd_float4x4?](repeating: nil, count: joints.count)
        func get(_ j: Int) -> simd_float4x4 {
            if let m = g[j] { return m }
            let p = joints[j].parent
            let m = (p >= 0 && p < joints.count ? get(p) : matrix_identity_float4x4) * local[j].matrix
            g[j] = m
            return m
        }
        return joints.indices.map(get)
    }

    /// The local poses of one frame of an animation (joints it doesn't animate keep their rest pose).
    func pose(_ clip: AnimClip, frame: Int, rest: [JointPose]) -> [JointPose] {
        joints.indices.map { j in
            if let t = clip.tracks[joints[j].nameHash], !t.isEmpty { return t[min(max(frame, 0), t.count - 1)] }
            return rest[j]
        }
    }
}

extension SkinnedMesh {
    /// The model deformed by a pose: each vertex follows its bones from the rest pose.
    func posed(_ sk: Skeleton, globals: [simd_float4x4]) -> SkinnedMesh {
        let skin = sk.joints.indices.map { globals[$0] * sk.joints[$0].bind.inverse }
        var out = self
        for v in positions.indices {
            var p = SIMD4<Float>(0, 0, 0, 0), n = SIMD3<Float>(0, 0, 0)
            for k in 0 ..< 4 where weights[v][k] > 0 {
                let inf = Int(boneIndices[v][k])
                guard inf < sk.influences.count else { continue }
                let m = skin[sk.influences[inf]]
                p += weights[v][k] * (m * SIMD4(positions[v], 1))
                let r = m * SIMD4(normals[v], 0)
                n += weights[v][k] * SIMD3(r.x, r.y, r.z)
            }
            out.positions[v] = SIMD3(p.x, p.y, p.z)
            out.normals[v] = simd_length(n) > 0 ? simd_normalize(n) : normals[v]
        }
        return out
    }
}
