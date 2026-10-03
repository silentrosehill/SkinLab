import Foundation
import ImageIO
import simd

/// Developer tools for looking inside game files (used from the command line, not the app's UI).
enum DebugDump {
    static let knownNames: [String] = [
        // classes
        "AnimationGraphData", "AtomicClipData", "SequencerClipData", "SelectorClipData", "ParallelClipData",
        "ConditionBoolClipData", "ConditionFloatClipData", "ConditionFloatPairData", "ConditionBoolPairData",
        "SubmeshVisibilityEventData", "ParticleEventData", "SoundEventData", "FadeEventData", "JointSnapEventData",
        "IdleParticlesVisibilityEventData", "EnableLookAtEventData", "LockRootOrientationEventData", "AnimationResourceData",
        "TrackData", "SyncGroupData", "MaskData", "TimeBlendData", "TransitionClipBlendData", "ClipBlendData",
        "SkinCharacterDataProperties", "SkinAnimationProperties", "SkinMeshDataProperties", "SelectorPairData",
        "StopAnimationEventData", "ConformToPathEventData", "SpeedUpEventData", "JointOrientationEventData",
        "SkinMeshDataProperties_MaterialOverride", "SyncedAnimationEventData", "FaceTargetEventData",
        // fields
        "mClipDataMap", "mTrackDataMap", "mMaskDataMap", "mSyncGroupDataMap", "mBlendDataTable", "mUseCascadeBlend",
        "mCascadeBlendValue", "mAnimationResourceData", "mAnimationFilePath", "mEventDataMap", "mFlags", "mTrackDataName",
        "mMaskDataName", "mSyncGroupDataName", "mTickDuration", "mClipNameList", "mStartFrame", "mEndFrame",
        "mShowSubmeshList", "mHideSubmeshList", "mName", "mIsSelfOnly", "mFireIfAnimationEndsEarly", "mEffectKey",
        "mParticleEventDataPairList", "mBoneName", "mEnemyEffectKey", "mIsLoop", "mIsKillEvent", "mScale", "mSoundName",
        "mIsDetachable", "mUpdaterTypeData", "mPairDataList", "mClipName", "mProbability", "mChildClipData",
        "mTrueConditionClipName", "mFalseConditionClipName", "mUpdaterType", "mChangeAnimationMidPlay",
        "mPlayAnimChangeFromBeginning", "mDontStompTransitionClip", "mChildAnimDelaySwitchTime", "animationGraphData",
        "skinAnimationProperties", "mPriority", "mBlendWeight", "mValue", "mEndFrameRatio", "mMaskName", "mJointHashes",
        "mWeightList", "mJointName", "mTargetJointName", "mIsPlayerOnly", "mUseSimpleBlend", "mTime", "mDuration",
        "mStartFrameRatio", "mIsMaskPlayer", "mParticleEventDataMap", "mEffectName", "mParentClipName",
        "simpleSkin", "skeleton", "texture", "material", "materialOverride", "submesh", "initialSubmeshToHide",
    ]

    static let names: [UInt32: String] = Dictionary(knownNames.map { (fnv($0), $0) }, uniquingKeysWith: { a, _ in a })

    static func name(_ h: UInt32) -> String { names[h] ?? String(format: "0x%08x", h) }

    static func describe(_ v: BinValue, depth: Int = 0, max: Int = 6) -> String {
        let pad = String(repeating: "  ", count: depth + 1)
        switch v {
        case let .string(s): return "\"\(s)\""
        case let .hash(h): return "hash " + name(h)
        case let .link(l): return "link " + name(l)
        case let .file(f): return String(format: "file %016llx", f)
        case let .raw(t, d): return describeRaw(t, d)
        case let .list(_, _, items):
            if depth >= max { return "[\(items.count) items]" }
            return "[\n" + items.map { pad + describe($0, depth: depth + 1, max: max) }.joined(separator: "\n") + "\n" + pad.dropLast(2) + "]"
        case let .embed(_, cls, fields):
            if cls == 0 { return "null" }
            if depth >= max { return name(cls) + " {…}" }
            return name(cls) + " {\n" + fields.map { pad + name($0.name) + ": " + describe($0.value, depth: depth + 1, max: max) }.joined(separator: "\n")
                + "\n" + pad.dropLast(2) + "}"
        case let .option(_, inner): return inner.map { "opt " + describe($0, depth: depth, max: max) } ?? "opt none"
        case let .map(_, _, kv):
            if depth >= max { return "{\(kv.count) entries}" }
            return "{\n" + kv.map { pad + describe($0.0, depth: depth + 1, max: max) + " => " + describe($0.1, depth: depth + 1, max: max) }
                .joined(separator: "\n") + "\n" + pad.dropLast(2) + "}"
        }
    }

    private static func describeRaw(_ t: UInt8, _ d: Data) -> String {
        let b = [UInt8](d)
        func f(_ o: Int) -> Float { Float(bitPattern: UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24) }
        switch t {
        case 1, 0x87: return b[0] != 0 ? "true" : "false"
        case 10 where b.count == 4: return String(format: "%g", f(0))
        case 7 where b.count == 4: return "u32 \(UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24)"
        case 6 where b.count == 4: return "i32 \(Int32(bitPattern: UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24))"
        default: return String(format: "raw 0x%02x ", t) + b.prefix(16).map { String(format: "%02x", $0) }.joined()
        }
    }

    static func kind(_ d: Data) -> String {
        if d.starts(with: Data("PROP".utf8)) { return "bin" }
        if d.starts(with: Data("PTCH".utf8)) { return "bin(patch)" }
        if d.starts(with: Data("r3d2anmd".utf8)) || d.starts(with: Data("r3d2canm".utf8)) { return "anm" }
        if d.starts(with: Data("TEX\0".utf8)) { return "tex" }
        if d.starts(with: Data("DDS ".utf8)) { return "dds" }
        if d.count > 8, d[d.startIndex + 4 ..< d.startIndex + 8] == Data([0xC3, 0x4F, 0xFD, 0x22]) { return "skl" }
        if d.starts(with: Data([0x33, 0x22, 0x11, 0x00])) { return "skn" }
        if d.starts(with: Data("r3d2Mesh".utf8)) { return "scb" }
        if d.starts(with: Data("BKHD".utf8)) { return "bnk" }
        if d.starts(with: Data("r3d2".utf8)) { return "r3d2?" }
        return "other"
    }

    /// Lists a WAD's contents by kind, and prints each .bin's links and top-level objects.
    static func listWad(_ url: URL, showBins: Bool) {
        guard let wad = try? Wad(url: url) else { print("can't open \(url.path)"); return }
        var counts: [String: Int] = [:]
        var bins: [(UInt64, Data)] = []
        for h in wad.entries.keys.sorted() {
            guard let d = try? wad.read(h) else { counts["unreadable", default: 0] += 1; continue }
            let k = kind(d)
            counts[k, default: 0] += 1
            if k == "bin" { bins.append((h, d)) }
        }
        print(counts.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: ", "))
        guard showBins else { return }
        for (h, d) in bins {
            guard let f = try? BinFile.parse(d) else { print(String(format: "%016llx.bin: can't parse", h)); continue }
            let classes = Dictionary(grouping: f.objects, by: { $0.cls }).map { "\(name($0.key))×\($0.value.count)" }
            print(String(format: "%016llx.bin", h), "links:", f.links, "objects:", classes.joined(separator: ", "))
        }
    }

    /// Prints every object of one .bin found in a WAD (by path) or a loose file.
    static func dumpBin(_ data: Data, max: Int) {
        guard let f = try? BinFile.parse(data) else { print("can't parse"); return }
        print("links:", f.links)
        for o in f.objects {
            print("\(name(o.cls)) @\(name(o.path)):")
            for fl in o.fields { print("  \(name(fl.name)): \(describe(fl.value, depth: 1, max: max))") }
        }
    }
}

extension DebugDump {
    /// A textured picture of a model in its rest pose (front, side), without porting or animation: for checking imports.
    static func renderRest(_ m: SkinData, to url: URL, side: Bool = false) {
        let mesh = m.mesh
        let w = 700, h = 900
        var color = [UInt8](repeating: 40, count: w * h * 4), depth = [Float](repeating: -.greatestFiniteMagnitude, count: w * h)
        let lo = mesh.positions.reduce(SIMD3<Float>(repeating: .greatestFiniteMagnitude)) { simd_min($0, $1) }
        let hi = mesh.positions.reduce(SIMD3<Float>(repeating: -.greatestFiniteMagnitude)) { simd_max($0, $1) }
        let scale = Float(h - 40) / max(hi.y - lo.y, 1)
        func project(_ p: SIMD3<Float>) -> SIMD3<Float> {
            let x = side ? p.z : p.x
            return SIMD3(Float(w) / 2 - x * scale, Float(h - 20) - (p.y - lo.y) * scale, side ? -p.x : p.z)
        }
        for part in mesh.parts {
            let tex = m.partTexture[part.name].flatMap { m.textures[$0]?.image }
            for t in stride(from: part.startIndex, to: part.startIndex + part.indexCount - 2, by: 3) {
                let ids = (0 ..< 3).map { Int(mesh.indices[t + $0]) }
                let p = ids.map { project(mesh.positions[$0]) }
                let x0 = max(0, Int(min(p[0].x, p[1].x, p[2].x))), x1 = min(w - 1, Int(max(p[0].x, p[1].x, p[2].x)) + 1)
                let y0 = max(0, Int(min(p[0].y, p[1].y, p[2].y))), y1 = min(h - 1, Int(max(p[0].y, p[1].y, p[2].y)) + 1)
                let area = (p[1].x - p[0].x) * (p[2].y - p[0].y) - (p[2].x - p[0].x) * (p[1].y - p[0].y)
                guard abs(area) > 1e-6, x0 <= x1, y0 <= y1 else { continue }
                for y in y0 ... y1 {
                    for x in x0 ... x1 {
                        let px = Float(x) + 0.5, py = Float(y) + 0.5
                        let b0 = ((p[1].x - px) * (p[2].y - py) - (p[2].x - px) * (p[1].y - py)) / area
                        let b1 = ((p[2].x - px) * (p[0].y - py) - (p[0].x - px) * (p[2].y - py)) / area
                        let b2 = 1 - b0 - b1
                        guard b0 >= 0, b1 >= 0, b2 >= 0 else { continue }
                        let z = b0 * p[0].z + b1 * p[1].z + b2 * p[2].z
                        let i = y * w + x
                        guard z > depth[i] else { continue }
                        depth[i] = z
                        var rgb: [UInt8] = [200, 200, 200]
                        if let tex {
                            let uv = b0 * mesh.uvs[ids[0]] + b1 * mesh.uvs[ids[1]] + b2 * mesh.uvs[ids[2]]
                            let tx = min(tex.width - 1, max(0, Int((uv.x - uv.x.rounded(.down)) * Float(tex.width))))
                            let ty = min(tex.height - 1, max(0, Int((uv.y - uv.y.rounded(.down)) * Float(tex.height))))
                            let o = (ty * tex.width + tx) * 4
                            rgb = [tex.pixels[o], tex.pixels[o + 1], tex.pixels[o + 2]]
                        }
                        color[i * 4] = rgb[0]; color[i * 4 + 1] = rgb[1]; color[i * 4 + 2] = rgb[2]
                    }
                }
            }
        }
        if let img = RGBAImage(width: w, height: h, pixels: color.enumerated().map { $0.offset % 4 == 3 ? 255 : $0.element }).cgImage,
           let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, img, nil)
            CGImageDestinationFinalize(dest)
        }
    }
}
