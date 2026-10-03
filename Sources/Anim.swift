import Foundation
import simd

/// Edits joint positions (translations) inside League animations, leaving rotations and timing untouched.
/// Handles compressed (r3d2canm) and uncompressed (r3d2anmd v3/v4/v5) files.
enum AnimEdit {
    typealias Change = (_ joint: UInt32, _ translation: SIMD3<Float>) -> SIMD3<Float>

    static func edit(_ data: Data, joints: Set<UInt32>, change: Change) throws -> Data {
        guard data.count > 12 else { throw FormatError("Animation is too short") }
        let magic = String(decoding: data.prefix(8), as: UTF8.self)
        let version = data.subdata(in: 8 ..< 12).withUnsafeBytes { $0.load(as: UInt32.self) }
        switch (magic, version) {
        case ("r3d2canm", _): return try compressed(data, joints, change)
        case ("r3d2anmd", 4), ("r3d2anmd", 5): return try uncompressed(data, v5: version == 5, joints, change)
        case ("r3d2anmd", 3): return try legacy(data, joints, change)
        default: throw FormatError("Unknown animation format \(magic) v\(version)")
        }
    }

    // MARK: Little-endian helpers

    private static func u16(_ d: [UInt8], _ o: Int) -> UInt16 { UInt16(d[o]) | UInt16(d[o + 1]) << 8 }
    private static func u32(_ d: [UInt8], _ o: Int) -> UInt32 { UInt32(u16(d, o)) | UInt32(u16(d, o + 2)) << 16 }
    private static func i32(_ d: [UInt8], _ o: Int) -> Int { Int(Int32(bitPattern: u32(d, o))) }
    private static func f32(_ d: [UInt8], _ o: Int) -> Float { Float(bitPattern: u32(d, o)) }
    private static func vec(_ d: [UInt8], _ o: Int) -> SIMD3<Float> { SIMD3(f32(d, o), f32(d, o + 4), f32(d, o + 8)) }
    private static func put16(_ d: inout [UInt8], _ o: Int, _ v: UInt16) { d[o] = UInt8(v & 0xFF); d[o + 1] = UInt8(v >> 8) }
    private static func put32(_ d: inout [UInt8], _ o: Int, _ v: UInt32) { put16(&d, o, UInt16(v & 0xFFFF)); put16(&d, o + 2, UInt16(v >> 16)) }
    private static func putF(_ d: inout [UInt8], _ o: Int, _ v: Float) { put32(&d, o, v.bitPattern) }
    private static func putVec(_ d: inout [UInt8], _ o: Int, _ v: SIMD3<Float>) { putF(&d, o, v.x); putF(&d, o + 4, v.y); putF(&d, o + 8, v.z) }

    // MARK: Compressed

    /// Translation keys are 3×16-bit values between a file-wide min and max: decode all of them, change the
    /// chosen joints', widen the range if needed and encode them all again. Curve timing is untouched.
    private static func compressed(_ data: Data, _ joints: Set<UInt32>, _ change: Change) throws -> Data {
        var d = [UInt8](data)
        let jointCount = i32(d, 24), frameCount = i32(d, 28)
        let minOff = 68, maxOff = 80
        let framesOff = i32(d, 116) + 12, hashesOff = i32(d, 124) + 12
        guard framesOff + frameCount * 10 <= d.count, hashesOff + jointCount * 4 <= d.count else { throw FormatError("Animation is truncated") }
        let hashes = (0 ..< jointCount).map { u32(d, hashesOff + $0 * 4) }
        let lo = vec(d, minOff), hi = vec(d, maxOff)

        var keys: [(offset: Int, value: SIMD3<Float>)] = []
        for f in 0 ..< frameCount {
            let o = framesOff + f * 10
            let jt = u16(d, o + 2)
            guard jt >> 14 == 1 else { continue }                      // translations only
            let joint = Int(jt & 0x3FFF)
            var v = SIMD3<Float>(Float(u16(d, o + 4)), Float(u16(d, o + 6)), Float(u16(d, o + 8))) / 65535 * (hi - lo) + lo
            if joint < hashes.count, joints.contains(hashes[joint]) { v = change(hashes[joint], v) }
            keys.append((o, v))
        }
        guard !keys.isEmpty else { return data }
        var newLo = lo, newHi = hi
        for k in keys { newLo = simd_min(newLo, k.value); newHi = simd_max(newHi, k.value) }
        putVec(&d, minOff, newLo)
        putVec(&d, maxOff, newHi)
        let range = newHi - newLo
        for k in keys {
            for c in 0 ..< 3 {
                let q = range[c] > 0 ? ((k.value[c] - newLo[c]) / range[c] * 65535).rounded() : 0
                put16(&d, k.offset + 4 + c * 2, UInt16(min(max(q, 0), 65535)))
            }
        }
        return Data(d)
    }

    // MARK: Uncompressed v4 / v5

    /// Frames point into a shared palette of vectors (translations and scales). The palette is rebuilt with the
    /// changed translations added, and the frames of the chosen joints point at them.
    private static func uncompressed(_ data: Data, v5: Bool, _ joints: Set<UInt32>, _ change: Change) throws -> Data {
        let d = [UInt8](data)
        let trackCount = i32(d, 28), frameCount = i32(d, 32)
        let hashesOff = i32(d, 40), vecOff = i32(d, 52), quatOff = i32(d, 56), framesOff = i32(d, 60)
        guard vecOff > 0, quatOff > vecOff, framesOff > 0 else { throw FormatError("Unsupported animation layout") }
        let vecCount = (quatOff - vecOff) / 12
        var palette = (0 ..< vecCount).map { vec(d, vecOff + 12 + $0 * 12) }
        let frameSize = v5 ? 6 : 12
        let hashes: [UInt32] = v5 ? (0 ..< trackCount).map { u32(d, hashesOff + 12 + $0 * 4) } : []

        var lookup: [SIMD3<Float>: Int] = [:]
        for (i, v) in palette.enumerated() where lookup[v] == nil { lookup[v] = i }
        var frames = Array(d[(framesOff + 12) ..< min(d.count, framesOff + 12 + trackCount * frameCount * frameSize)])
        for f in 0 ..< frameCount {
            for t in 0 ..< trackCount {
                let o = (f * trackCount + t) * frameSize
                let hash = v5 ? hashes[t] : u32(frames, o)
                guard joints.contains(hash) else { continue }
                let tOff = v5 ? o : o + 4
                let id = Int(u16(frames, tOff))
                guard id < palette.count else { continue }
                let nv = change(hash, palette[id])
                var nid = lookup[nv]
                if nid == nil {
                    guard palette.count < 65536 else { throw FormatError("Animation has too many positions to edit") }
                    palette.append(nv)
                    nid = palette.count - 1
                    lookup[nv] = nid
                }
                put16(&frames, tOff, UInt16(nid!))
            }
        }

        // Everything after the vector palette moves by the palette's growth.
        let grow = (palette.count - vecCount) * 12
        var out = Array(d[0 ..< (vecOff + 12)])
        for v in palette { var b = [UInt8](repeating: 0, count: 12); putVec(&b, 0, v); out += b }
        var rest = Array(d[(quatOff + 12)...])
        let framesStartInRest = framesOff - quatOff
        for i in 0 ..< frames.count where framesStartInRest + i < rest.count { rest[framesStartInRest + i] = frames[i] }
        out += rest
        for field in [40, 44, 48, 56, 60] {          // joint hashes, asset name, time, quats, frames
            let v = i32(d, field)
            if v > vecOff { put32(&out, field, UInt32(bitPattern: Int32(v + grow))) }
        }
        put32(&out, 12, UInt32(out.count - 12))      // resource size (after the 12-byte signature)
        return Data(out)
    }

    // MARK: Legacy v3

    private static func legacy(_ data: Data, _ joints: Set<UInt32>, _ change: Change) throws -> Data {
        var d = [UInt8](data)
        let trackCount = i32(d, 16), frameCount = i32(d, 20)
        var o = 28
        for _ in 0 ..< trackCount {
            guard o + 36 + frameCount * 28 <= d.count else { throw FormatError("Animation is truncated") }
            let name = String(decoding: d[o ..< o + 32].prefix { $0 != 0 }, as: UTF8.self)
            let hash = Skeleton.elf(name)
            o += 36
            for _ in 0 ..< frameCount {
                if joints.contains(hash) { putVec(&d, o + 16, change(hash, vec(d, o + 16))) }
                o += 28
            }
        }
        return Data(d)
    }

    /// Every translation key of the given joints, in file order (for checking edits).
    static func allTranslations(_ data: Data, joints: Set<UInt32>) -> [SIMD3<Float>] {
        var seen: [SIMD3<Float>] = []
        _ = try? edit(data, joints: joints) { _, v in seen.append(v); return v }
        return seen
    }

    /// Debug: the translations of one joint across an animation (first, middle, last key).
    static func sampleTranslations(_ data: Data, joint: UInt32) -> [SIMD3<Float>] {
        var seen: [SIMD3<Float>] = []
        _ = try? edit(data, joints: [joint]) { _, v in seen.append(v); return v }
        guard !seen.isEmpty else { return [] }
        return [seen[0], seen[seen.count / 2], seen[seen.count - 1]]
    }
}
