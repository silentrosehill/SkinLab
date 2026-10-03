import Foundation
import simd

// MARK: - Where files come from

/// Anything that can hand out game files by path hash: a WAD, a mod folder, or several stacked.
protocol FileSource: AnyObject {
    func data(_ hash: UInt64) -> Data?
}

extension Wad: FileSource {
    func data(_ hash: UInt64) -> Data? { try? read(hash) }
}

/// A mod's WAD unpacked as a folder: files named by path, or by hash ("0123456789abcdef.tex").
final class FolderSource: FileSource {
    private var files: [UInt64: URL] = [:]

    init(_ dir: URL) {
        let base = dir.standardizedFileURL.path
        guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let rel = String(url.standardizedFileURL.path.dropFirst(base.count + 1))
            let stem = rel.split(separator: ".").first.map(String.init) ?? rel
            if stem.count == 16, let h = UInt64(stem, radix: 16) { files[h] = url } else { files[pathHash(rel)] = url }
        }
    }

    func data(_ hash: UInt64) -> Data? { files[hash].flatMap { try? Data(contentsOf: $0) } }
}

/// The first source that has a file wins (a mod over the game).
final class Layered: FileSource {
    let sources: [FileSource]
    init(_ sources: [FileSource]) { self.sources = sources }
    func data(_ hash: UInt64) -> Data? {
        for s in sources { if let d = s.data(hash) { return d } }
        return nil
    }
}

// MARK: - A loaded skin

struct SkinData {
    var bin: BinFile
    var propsIndex: Int
    var mesh: SkinnedMesh
    var skeleton: Skeleton?
    var skeletonData: Data? = nil
    var partTexture: [String: UInt64]
    var textures: [UInt64: (data: Data, image: RGBAImage)]
    var textureOrder: [UInt64]
    var hideAtStart: [String]

    var meshProps: BinValue { bin.objects[propsIndex]["skinMeshProperties"] ?? .embed(kind: 0x83, cls: 0, fields: []) }

    static func binHash(_ champion: String, _ num: Int) -> UInt64 {
        pathHash("data/characters/\(champion.lowercased())/skins/skin\(num).bin")
    }

    /// Reads skinN.bin, then the model, skeleton and every texture its parts use.
    static func load(_ source: FileSource, champion: String, num: Int, needSkeleton: Bool = false) throws -> SkinData {
        guard let binData = source.data(binHash(champion, num)) else { throw FormatError("Skin \(num) not found") }
        let bin = try BinFile.parse(binData)
        guard let propsIndex = bin.objects.firstIndex(where: { $0.cls == fnv("SkinCharacterDataProperties") }),
              let meshProps = bin.objects[propsIndex]["skinMeshProperties"] else { throw FormatError("This skin has no model data") }
        guard let sknHash = meshProps["simpleSkin"]?.fileHash, let sknData = source.data(sknHash) else {
            throw FormatError("This skin's model file is missing")
        }
        let mesh = try SkinnedMesh.parse(sknData)
        var skeleton: Skeleton?
        var skeletonData: Data?
        if let sklHash = meshProps["skeleton"]?.fileHash, let d = source.data(sklHash) { skeleton = try? Skeleton.parse(d); skeletonData = d }
        if needSkeleton, skeleton == nil { throw FormatError("This skin's skeleton couldn't be read") }

        let byPath = Dictionary(bin.objects.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        /// The main color texture of a material defined in this bin.
        func materialTexture(_ link: UInt32?) -> UInt64? {
            guard let link, let mat = byPath[link] else { return nil }
            var samplers: [(name: String, file: UInt64)] = []
            for field in mat.fields {
                field.value.walk { v in
                    guard case .embed = v, let file = v["texturePath"]?.fileHash ?? v["texture"]?.fileHash else { return }
                    samplers.append((v["textureName"]?.string ?? v["samplerName"]?.string ?? "", file))
                }
            }
            let preferred = samplers.first { $0.name.lowercased().contains("diffuse") }
                ?? samplers.first { !$0.name.lowercased().contains("mask") }
            return (preferred ?? samplers.first)?.file
        }

        let defaultTexture = meshProps["texture"]?.fileHash ?? materialTexture(meshProps["material"]?.link)
        var partTexture: [String: UInt64] = [:]
        for part in mesh.parts { if let t = defaultTexture { partTexture[part.name] = t } }
        for o in meshProps["materialOverride"]?.items ?? [] {
            guard let submesh = o["submesh"]?.string else { continue }
            let tex = o["texture"]?.fileHash ?? materialTexture(o["material"]?.link)
            for part in mesh.parts where part.name.lowercased() == submesh.lowercased() { partTexture[part.name] = tex }
        }

        var textures: [UInt64: (Data, RGBAImage)] = [:]
        var order: [UInt64] = []
        for part in mesh.parts {
            guard let h = partTexture[part.name] else { continue }
            if textures[h] != nil { continue }
            guard let data = source.data(h), let image = try? TextureFile.decode(data) else {
                partTexture[part.name] = nil
                continue
            }
            textures[h] = (data, image)
            order.append(h)
        }
        let hide = (meshProps["initialSubmeshToHide"]?.string ?? "")
            .split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init).filter { !$0.isEmpty }
        return SkinData(bin: bin, propsIndex: propsIndex, mesh: mesh, skeleton: skeleton, skeletonData: skeletonData, partTexture: partTexture,
                        textures: textures, textureOrder: order, hideAtStart: hide)
    }
}

// MARK: - Animation clips of a skin

struct ClipInfo {
    let name: UInt32          // FNV hash of the clip name ("Spell1", "Attack1"…)
    let label: String         // readable name when known
    let file: UInt64?         // the animation file it plays
    let path: String?         // that file's path, when stored as text
    /// Show/hide events for model parts (by FNV hash of the part name), at a frame.
    var partEvents: [(frame: Float, show: [UInt32], hide: [UInt32])] = []
    /// For a clip made of pieces played one after another (Yone's Q: "Spell1A_01" then "Spell1A_02"): their files.
    var sequence: [UInt64] = []

    /// Its animation (the pieces joined for a sequence).
    func animation(_ files: FileSource) -> AnimClip? {
        if let file { return files.data(file).flatMap { try? AnimClip.decode($0) } }
        let pieces = sequence.compactMap { files.data($0).flatMap { try? AnimClip.decode($0) } }
        guard let first = pieces.first, pieces.count == sequence.count else { return nil }
        let joints = pieces.dropFirst().reduce(Set(first.tracks.keys)) { $0.intersection($1.tracks.keys) }
        var out = AnimClip(fps: first.fps, frameCount: pieces.reduce(0) { $0 + $1.frameCount }, tracks: [:])
        for h in joints { out.tracks[h] = pieces.flatMap { $0.tracks[h]! } }
        return out
    }
}

extension SkinData {
    static let commonClipNames: [String] = {
        var n = ["Idle1", "Idle2", "Idle3", "Idle4", "Idle_Base", "Idle1_IN", "Idle1_IN2", "Idle1_IN3", "Idle_Loop", "Idle_IN", "Run", "Run_Base",
                 "Run_Fast", "Run_Haste", "Run_IN", "Run_In2", "Run2", "Attack1", "Attack2", "Attack3", "Attack4", "Crit", "Death", "Recall",
                 "Recall_Return", "Recall_Winddown", "Dance", "Dance_IN", "Dance_Loop", "Laugh", "Taunt", "Joke", "Channel", "Channel_WNDUP",
                 "Respawn", "Spawn", "Homeguard", "Run_Homeguard"]
        for s in 1 ... 4 {
            n += ["Spell\(s)", "Spell\(s)_2", "Spell\(s)_2_to_idle", "Spell\(s)A", "Spell\(s)B", "Spell\(s)C", "Spell\(s)_IN", "Spell\(s)_Loop",
                  "Spell\(s)_OUT", "Spell\(s)_to_Idle", "Spell\(s)_0", "Spell\(s)_90", "Spell\(s)_-90", "Spell\(s)_180", "Spell\(s)_-180",
                  "Spell\(s)_Dash1", "Spell\(s)_Dash2", "Spell\(s)_Hit", "Spell\(s)_Wall", "Spell\(s)_Attack", "Spell\(s)_Run"]
        }
        return n
    }()
    static let clipLabels: [UInt32: String] = Dictionary(commonClipNames.map { (fnv($0), $0) }, uniquingKeysWith: { a, _ in a })

    /// The animation graph's objects: in a linked animations .bin (game skins) or in the skin .bin itself (some mods).
    static func animationGraph(_ bin: BinFile, source: FileSource) -> (binPath: String?, file: BinFile)? {
        if bin.objects.contains(where: { $0.cls == fnv("AnimationGraphData") }) { return (nil, bin) }
        for link in bin.links where link.lowercased().contains("/animations/") {
            if let d = source.data(pathHash(link)), let f = try? BinFile.parse(d) { return (link, f) }
        }
        return nil
    }

    /// Clips made of pieces played one after another (a SequencerClipData of simple clips), e.g. Yone's Q.
    func sequences(_ source: FileSource) -> [ClipInfo] {
        guard let graph = Self.animationGraph(bin, source: source),
              let g = graph.file.objects.first(where: { $0.cls == fnv("AnimationGraphData") }),
              case let .map(_, _, entries)? = g["mClipDataMap"] else { return [] }
        let simple = Dictionary(clips(source).compactMap { c in c.file.map { (c.name, $0) } }, uniquingKeysWith: { a, _ in a })
        return entries.compactMap { key, value in
            guard case let .hash(name) = key, case let .embed(_, cls, _) = value, cls == fnv("SequencerClipData"),
                  let list = value["mClipNameList"]?.items, !list.isEmpty else { return nil }
            let files = list.compactMap { v -> UInt64? in if case let .hash(h) = v { return simple[h] }; return nil }
            guard files.count == list.count else { return nil }
            return ClipInfo(name: name, label: Self.clipLabels[name] ?? String(format: "%08x", name), file: nil, path: nil, sequence: files)
        }
    }

    /// Every simple clip (one animation file) of this skin's animation graph.
    func clips(_ source: FileSource) -> [ClipInfo] {
        guard let graph = Self.animationGraph(bin, source: source),
              let g = graph.file.objects.first(where: { $0.cls == fnv("AnimationGraphData") }),
              case let .map(_, _, entries)? = g["mClipDataMap"] else { return [] }
        return entries.compactMap { key, value in
            guard case let .hash(name) = key, let res = value["mAnimationResourceData"] else { return nil }
            let fileValue = res["mAnimationFilePath"]
            let path = fileValue?.string
            let stem = path.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
            var events: [(frame: Float, show: [UInt32], hide: [UInt32])] = []
            if case let .map(_, _, evs)? = value["mEventDataMap"] {
                for (_, e) in evs {
                    guard case let .embed(_, cls, _) = e, cls == fnv("SubmeshVisibilityEventData") else { continue }
                    var start: Float = 0
                    if case let .raw(0x0A, d)? = e["mStartFrame"], d.count == 4 { start = d.withUnsafeBytes { $0.load(as: Float.self) } }
                    func hashes(_ v: BinValue?) -> [UInt32] { (v?.items ?? []).compactMap { if case let .hash(h) = $0 { return h }; return nil } }
                    events.append((start, hashes(e["mShowSubmeshList"]), hashes(e["mHideSubmeshList"])))
                }
            }
            return ClipInfo(name: name, label: Self.clipLabels[name] ?? stem ?? String(format: "%08x", name),
                            file: fileValue?.fileHash, path: path, partEvents: events)
        }
    }
}

// MARK: - Porting a skin onto another champion

enum KeepRegion: String, CaseIterable, Identifiable {
    case head = "Head and hair"
    case hands = "Hands"
    case lowerLegs = "Lower legs"
    case feet = "Feet"
    var id: String { rawValue }

    /// Joints of these roles, and everything under them, make up the region.
    var roles: [Porter.Role] {
        switch self {
        case .head: return [.head]
        case .hands: return [.hand]
        case .lowerLegs: return [.calf]
        case .feet: return [.foot]
        }
    }
}

struct PortResult {
    var mesh: SkinnedMesh
    var partTexture: [String: UInt64]
    /// Source textures that become new files, with the path they'll be saved under.
    var newTexturePaths: [UInt64: String]
    var textures: [UInt64: (data: Data, image: RGBAImage)]
    var textureOrder: [UInt64]
    var hideAtStart: [String]
    var matchedBones: Int
    var sourceBones: Int
    /// Set with "normal proportions": the target's shortened skeleton and how it was changed.
    var legPlan: LegPlan? = nil
    var skeleton: Skeleton? = nil
    /// How much bigger the skin must be drawn to stand as tall as the champion normally does.
    var heightRatio: Float = 1
    /// Props that end up far from the bone they follow (emote/recall props, items of bones the champion lacks):
    /// they'd float beside the champion, so they start switched off.
    var farParts: [String] = []
}

enum Porter {
    /// Joints that carry a held item: never dropped when keeping the target's hands etc.
    private static func isItem(_ name: String) -> Bool {
        let n = name.lowercased()
        return ["weapon", "sword", "blade", "gun", "staff", "shield", "bow", "flute", "instrument", "sheath", "pistol", "launcher", "minigun", "spear", "axe", "hammer"]
            .contains { n.contains($0) }
    }

    enum Role: Hashable { case pelvis, spine, neck, head, clavicle, upperArm, foreArm, hand, thigh, knee, calf, foot, toe }

    struct RoleInfo: Hashable {
        let role: Role
        let side: Character?    // "l", "r", or nil for the middle
    }

    /// Lowercase words of a joint name, whatever the rig: "L_Hand", "Bip001 L Hand", "LeftHand", "hand_l"…
    static func words(_ name: String) -> [String] {
        var spaced = ""
        var prev: Character = " "
        for ch in name.replacingOccurrences(of: "FBXASC032", with: " ") {
            if ch.isUppercase && (prev.isLowercase || prev.isNumber) { spaced.append(" ") }
            spaced.append(ch)
            prev = ch
        }
        let junk: Set<String> = ["bip001", "bip01", "bip", "mixamorig", "def", "jnt", "joint", "bn", "b", "c", "m", "org", "mch"]
        return spaced.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { !junk.contains($0) }
    }

    static func roles(_ sk: Skeleton) -> [RoleInfo?] {
        var out: [RoleInfo?] = []
        var raw: [(String, Character?)] = []
        for j in sk.joints {
            var w = words(j.name)
            var side: Character?
            if w.contains("l") || w.contains("left") { side = "l" }
            if w.contains("r") || w.contains("right") { side = "r" }
            w.removeAll { ["l", "r", "left", "right"].contains($0) }
            raw.append((w.joined(), side))
        }
        // "Shoulder" is the upper arm in League rigs (they have a clavicle) but the clavicle in Mixamo rigs.
        let hasClavicle = raw.contains { $0.0 == "clavicle" || $0.0 == "collarbone" }
        for (w, side) in raw {
            let helper = ["twist", "end", "nub", "top", "roll", "sleeve", "buffbone", "cylinder", "pad", "pauldron", "ik", "pole", "target"]
                .contains { w.contains($0) }
            var role: Role?
            if !helper {
                switch w {
                case "pelvis", "hips": role = .pelvis
                case "hip": role = side == nil ? .pelvis : .thigh
                case let x where x.hasPrefix("spine") || x == "chest" || x == "upperchest": role = .spine
                case let x where x.hasPrefix("neck"): role = .neck
                case "head": role = .head
                case "clavicle", "collarbone": role = .clavicle
                case "shoulder": role = hasClavicle ? .upperArm : .clavicle
                case "upperarm", "uparm", "arm": role = .upperArm
                case "forearm", "lowerarm", "elbow": role = .foreArm
                case "hand", "wrist": role = .hand
                case "thigh", "upleg", "upperleg": role = .thigh
                case "knee", "kneeupper": role = .knee
                case "calf", "leg", "lowerleg", "shin", "kneelower": role = .calf
                case "foot", "ankle": role = .foot
                case let x where x.hasPrefix("toe"): role = .toe
                default: role = nil
                }
            }
            if let role, [.pelvis, .spine, .neck, .head].contains(role) || side != nil {
                out.append(RoleInfo(role: role, side: [.pelvis, .spine, .neck, .head].contains(role) ? nil : side))
            } else {
                out.append(nil)
            }
        }
        return out
    }

    private static func next(_ r: Role) -> [Role] {
        switch r {
        case .spine: return [.spine, .neck]
        case .neck: return [.head]
        case .clavicle: return [.upperArm]
        case .upperArm: return [.foreArm]
        case .foreArm: return [.hand]
        case .thigh: return [.knee, .calf, .foot]
        case .knee: return [.calf, .foot]
        case .calf: return [.foot]
        default: return []
        }
    }

    /// Source joint → target joint with the same role: same name first, then the same body part.
    static func matchJoints(_ s: Skeleton, _ t: Skeleton) -> [Int?] {
        var byName: [String: Int] = [:]
        for (i, j) in t.joints.enumerated() where byName[j.name.lowercased()] == nil { byName[j.name.lowercased()] = i }
        let sr = roles(s), tr = roles(t)
        var byRole: [RoleInfo: [Int]] = [:]
        for (i, r) in tr.enumerated() { if let r { byRole[r, default: []].append(i) } }
        func spineOrder(_ sk: Skeleton, _ rs: [RoleInfo?]) -> [Int] {
            rs.indices.filter { rs[$0]?.role == .spine }.sorted { sk.joints[$0].position.y < sk.joints[$1].position.y }
        }
        let sSpine = spineOrder(s, sr), tSpine = spineOrder(t, tr)

        return s.joints.indices.map { i in
            if let exact = byName[s.joints[i].name.lowercased()] { return exact }
            guard let r = sr[i] else { return nil }
            if r.role == .spine, !tSpine.isEmpty, let k = sSpine.firstIndex(of: i) {
                let f = sSpine.count > 1 ? Float(k) / Float(sSpine.count - 1) : 1
                return tSpine[Int((f * Float(tSpine.count - 1)).rounded())]
            }
            let fallbacks: [Role] = r.role == .calf ? [.calf, .knee] : r.role == .knee ? [.knee, .calf] : [r.role]
            for role in fallbacks {
                if let hit = byRole[RoleInfo(role: role, side: r.side)]?.first { return hit }
            }
            return nil
        }
    }

    private struct BoneMove {
        var from: SIMD3<Float>       // joint position in the source (after global alignment)
        var to: SIMD3<Float>         // where it lands on the target
        var axis: SIMD3<Float>?      // limb direction in the source, for stretching
        var stretch: Float = 1
        var rotation = simd_quatf(angle: 0, axis: SIMD3(0, 1, 0))

        func apply(_ p: SIMD3<Float>) -> SIMD3<Float> {
            var v = p - from
            // Stretch only what lies along the limb past the joint: things behind it (a skirt on a knee bone,
            // a shoulder pad on an elbow) keep their shape instead of being pushed away.
            if let axis {
                let along = simd_dot(v, axis)
                if along > 0 { v += (stretch - 1) * along * axis }
            }
            return to + rotation.act(v)
        }
    }

    /// Legs as long as the source character's (scaled like its torso), the body lowered so the feet stay down.
    static func legPlan(_ ss: Skeleton, _ ts: Skeleton) -> LegPlan? {
        let sr = roles(ss), tr = roles(ts)
        func find(_ rs: [RoleInfo?], _ role: Role, _ side: Character?) -> Int? { rs.firstIndex { $0 == RoleInfo(role: role, side: side) } }
        guard let sp = find(sr, .pelvis, nil), let sh = find(sr, .head, nil), let tp = find(tr, .pelvis, nil), let th = find(tr, .head, nil) else { return nil }
        let sTorso = simd_distance(ss.joints[sp].position, ss.joints[sh].position)
        guard sTorso > 1 else { return nil }
        let scale = simd_distance(ts.joints[tp].position, ts.joints[th].position) / sTorso
        func len(_ sk: Skeleton, _ a: Int, _ b: Int) -> Float { simd_distance(sk.joints[a].position, sk.joints[b].position) }
        var scales: [Int: Float] = [:]
        var feet: [Int] = []
        for side: Character in ["l", "r"] {
            guard let sHip = find(sr, .thigh, side), let sFoot = find(sr, .foot, side),
                  let tHip = find(tr, .thigh, side), let tFoot = find(tr, .foot, side),
                  let sKnee = find(sr, .knee, side) ?? find(sr, .calf, side),
                  let tKnee = find(tr, .knee, side) ?? find(tr, .calf, side) else { continue }
            let sLower = find(sr, .calf, side) ?? sKnee, tLower = find(tr, .calf, side) ?? tKnee
            let tThigh = len(ts, tHip, tKnee), tShin = len(ts, tLower, tFoot)
            guard tThigh > 1, tShin > 1, ts.joints[tFoot].parent == tLower else { continue }
            scales[tKnee] = min(max(len(ss, sHip, sKnee) * scale / tThigh, 0.3), 1.5)
            scales[tFoot] = min(max(len(ss, sLower, sFoot) * scale / tShin, 0.3), 1.5)
            feet.append(tFoot)
        }
        guard let firstFoot = feet.first else { return nil }
        var root = firstFoot
        while ts.joints[root].parent >= 0 { root = ts.joints[root].parent }
        var plan = LegPlan(bodyRoot: root, drop: 0, scales: scales, rootBindHeight: ts.joints[root].local.y)
        let d = ts.displacements(plan)
        plan.drop = feet.map { d[$0].y }.reduce(0, +) / Float(feet.count)
        return plan
    }

    static func port(source: SkinData, target original: SkinData, keep: Set<KeepRegion>, naturalLegs: Bool = false,
                     weapon: WeaponSwap? = nil, held: [WeaponSwap.Held] = [], sourceName: String, targetName: String) throws -> PortResult {
        guard let ss = source.skeleton, let originalSkeleton = original.skeleton else { throw FormatError("Both skins need a skeleton") }
        var target = original
        var plan: LegPlan?
        if naturalLegs, let p = legPlan(ss, originalSkeleton), abs(p.drop) > 0.5 {
            // Shorter legs: move the target's skeleton, and its own model with it (for kept parts).
            let d = originalSkeleton.displacements(p)
            target.skeleton = originalSkeleton.applying(p)
            let m = original.mesh
            target.mesh.positions = m.positions.indices.map { v in
                var shift = SIMD3<Float>(0, 0, 0)
                for k in 0 ..< 4 {
                    let inf = Int(m.boneIndices[v][k])
                    if inf < originalSkeleton.influences.count { shift += m.weights[v][k] * d[originalSkeleton.influences[inf]] }
                }
                return m.positions[v] + shift
            }
            plan = p
        }
        // With a weapon swap: the shift of the champion's weapon joint (shorter legs move it too).
        let weaponShift = plan.map { originalSkeleton.displacements($0)[weapon?.targetJoint ?? 0] } ?? SIMD3<Float>(0, 0, 0)
        let ts = target.skeleton!
        var direct = matchJoints(ss, ts)
        let sRoles = roles(ss), tRoles = roles(ts)
        func first(_ role: Role, _ rs: [RoleInfo?], side: Character? = nil) -> Int? {
            rs.firstIndex { $0?.role == role && $0?.side == side }
        }
        if ProcessInfo.processInfo.environment["SKINLAB_DEBUG"] != nil {
            for (i, j) in ss.joints.enumerated() {
                let p = j.position
                print(String(format: "%3d %-26@ parent %3d pos %6.1f %6.1f %6.1f -> %@", i, j.name as NSString, j.parent, p.x, p.y, p.z,
                             (direct[i].map { ts.joints[$0].name } ?? "-") as NSString))
            }
        }

        // Nearest matched ancestor for joints with no match of their own (capes, swords, hair…).
        var effective = [Int?](repeating: nil, count: ss.joints.count)
        func resolve(_ i: Int, _ depth: Int = 0) -> Int? {
            if let d = direct[i] { return d }
            let p = ss.joints[i].parent
            return p >= 0 && depth < 200 ? resolve(p, depth + 1) : nil
        }
        for i in ss.joints.indices { effective[i] = resolve(i) }
        let fallbackTarget = first(.pelvis, tRoles) ?? ts.index(named: "Root") ?? ts.influences.first ?? 0

        // Held props of other rigs ("Prop1", "Weapon"…) hanging off the body root go into the matching hand.
        var propJoints = Set<Int>()
        for i in ss.joints.indices where direct[i] == nil {
            let n = ss.joints[i].name.lowercased()
            guard n.contains("prop") || isItem(n) else { continue }
            let anchor = effective[i]
            guard anchor == nil || anchor == fallbackTarget || tRoles[anchor!]?.role == .spine else { continue }
            let w = words(ss.joints[i].name)
            let side: Character = w.contains("l") || w.contains("left") ? "l"
                : w.contains("r") || w.contains("right") || n.contains("prop1") ? "r"
                : ss.joints[i].position.x < 0 ? "l" : "r"
            if let hand = first(.hand, tRoles, side: side) {
                direct[i] = hand
                propJoints.insert(i)
            }
        }
        for i in ss.joints.indices { effective[i] = resolve(i) }

        // 1. Line the bodies up: same pelvis spot, same torso height.
        var scale: Float = 1
        var sAnchor = SIMD3<Float>(0, 0, 0), tAnchor = SIMD3<Float>(0, 0, 0)
        if let sp = first(.pelvis, sRoles), let sh = first(.head, sRoles),
           let tp = first(.pelvis, tRoles), let th = first(.head, tRoles) {
            let sLen = simd_distance(ss.joints[sp].position, ss.joints[sh].position)
            let tLen = simd_distance(ts.joints[tp].position, ts.joints[th].position)
            if sLen > 1 { scale = tLen / sLen }
            sAnchor = ss.joints[sp].position
            tAnchor = ts.joints[tp].position
        } else {
            let sh = (source.mesh.positions.map(\.y).max() ?? 1) - (source.mesh.positions.map(\.y).min() ?? 0)
            let th = (target.mesh.positions.map(\.y).max() ?? 1) - (target.mesh.positions.map(\.y).min() ?? 0)
            if sh > 1 { scale = th / sh }
        }
        func align(_ p: SIMD3<Float>) -> SIMD3<Float> { tAnchor + scale * (p - sAnchor) }

        // 2. Each matched joint moves onto its target; limbs also turn and stretch to the target's limb.
        var moves = [BoneMove?](repeating: nil, count: ss.joints.count)
        var children = [[Int]](repeating: [], count: ss.joints.count)
        for (i, j) in ss.joints.enumerated() where j.parent >= 0 && j.parent < ss.joints.count { children[j.parent].append(i) }

        func limbChild(_ i: Int) -> Int? {
            guard let c = sRoles[i], !next(c.role).isEmpty, let ti = direct[i] else { return nil }
            var queue = children[i]
            while !queue.isEmpty {
                let k = queue.removeFirst()
                if let kc = sRoles[k], next(c.role).contains(kc.role),
                   kc.side == c.side, let tk = direct[k], ts.isAncestor(ti, of: tk),
                   simd_distance(ss.joints[i].position, ss.joints[k].position) * scale > 1,
                   simd_distance(ts.joints[ti].position, ts.joints[tk].position) > 1 {
                    return k
                }
                queue += children[k]
            }
            return nil
        }

        // Parents first, so a joint without its own direction can inherit its parent limb's turn.
        var order: [Int] = []
        var seen = Set<Int>()
        func visit(_ i: Int) {
            guard !seen.contains(i) else { return }
            seen.insert(i)
            if ss.joints[i].parent >= 0 && ss.joints[i].parent < ss.joints.count { visit(ss.joints[i].parent) }
            order.append(i)
        }
        ss.joints.indices.forEach(visit)

        // The torso, neck and head keep their own shape (scaled as one piece): stretching each spine segment to the
        // target's spacing squashes or pulls the chest. Only arms and legs are fitted limb by limb.
        let sourcePelvis = sRoles.firstIndex { $0?.role == .pelvis }
        func isTorso(_ i: Int) -> Bool {
            if let r = sRoles[i]?.role, [.pelvis, .spine, .neck, .head].contains(r) { return true }
            if let p = sourcePelvis { return ss.isAncestor(i, of: p) }    // "Root" and the like above the pelvis
            return false
        }
        for i in order {
            guard let ti = direct[i] else { continue }
            if isTorso(i) {
                let p = align(ss.joints[i].position)
                moves[i] = BoneMove(from: p, to: p)
                continue
            }
            var move = BoneMove(from: align(ss.joints[i].position), to: ts.joints[ti].position)
            if let k = limbChild(i), let tk = direct[k] {
                let ds = align(ss.joints[k].position) - move.from
                let dt = ts.joints[tk].position - move.to
                move.axis = simd_normalize(ds)
                move.stretch = min(max(simd_length(dt) / simd_length(ds), 0.3), 3.5)
                move.rotation = simd_quatf(from: simd_normalize(ds), to: simd_normalize(dt))
            } else {
                var p = ss.joints[i].parent
                while p >= 0 && p < ss.joints.count {
                    if let pm = moves[p] { move.rotation = pm.rotation; break }
                    p = ss.joints[p].parent
                }
            }
            moves[i] = move
        }
        func moveFor(_ joint: Int) -> BoneMove? {
            var j = joint
            while j >= 0 && j < ss.joints.count {
                if let m = moves[j] { return m }
                j = ss.joints[j].parent
            }
            return nil
        }

        // 3. Bone index in the target model for a target joint (walking up to one the model uses).
        var influenceOf: [Int: Int] = [:]
        for (i, j) in ts.influences.enumerated() where influenceOf[j] == nil { influenceOf[j] = i }
        func targetInfluence(_ joint: Int) -> Int {
            var j = joint
            while j >= 0 && j < ts.joints.count {
                if let i = influenceOf[j] { return i }
                j = ts.joints[j].parent
            }
            return influenceOf[fallbackTarget] ?? 0
        }

        // Region membership for "keep the target's own …".
        func regionJoints(_ sk: Skeleton, skipItems: Bool) -> Set<Int> {
            var roots = Set<Int>()
            let rs = roles(sk)
            for r in keep { for i in rs.indices where rs[i].map({ r.roles.contains($0.role) }) == true { roots.insert(i) } }
            var out = Set<Int>()
            for i in sk.joints.indices {
                if skipItems && isItem(sk.joints[i].name) { continue }
                if roots.contains(i) || roots.contains(where: { sk.isAncestor($0, of: i) }) { out.insert(i) }
            }
            return out
        }
        let sourceRegion = regionJoints(ss, skipItems: true).subtracting(propJoints)
        let targetRegion = regionJoints(ts, skipItems: false)

        // The target's head, neck height and upper chest (for hair and cloth hanging from the head).
        let targetHead = tRoles.firstIndex { $0?.role == .head }
        let neckHeight = (tRoles.firstIndex { $0?.role == .neck }).map { ts.joints[$0].position.y } ?? .greatestFiniteMagnitude
        let targetChest = tRoles.indices.filter { tRoles[$0]?.role == .spine }.max { ts.joints[$0].position.y < ts.joints[$1].position.y }
        let targetTorso = tRoles.indices.filter { [.pelvis, .spine].contains(tRoles[$0]?.role) }
        // Cords and cloth hanging from an arm that reach far from it (pendants, sashes the skin moved with physics): the
        // whole chain follows the nearest parts of the torso instead, keeping its shape (no swinging with the arm).
        var torsoChain: [Int: Int] = [:]
        if !targetTorso.isEmpty {
            for j in ss.joints.indices where direct[j] == nil {
                guard let e = effective[j], let r = tRoles[e]?.role, [.clavicle, .upperArm, .foreArm, .hand].contains(r) else { continue }
                var top = j
                while ss.joints[top].parent >= 0, direct[ss.joints[top].parent] == nil, effective[ss.joints[top].parent] == e { top = ss.joints[top].parent }
                guard torsoChain[top] == nil || top == j else { continue }
                let below = ss.joints.indices.filter { m in m == top || ss.isAncestor(top, of: m) }
                // Not part of the limb itself (twist bones between the arm's joints, fingers): nothing matched hangs below.
                guard !below.contains(where: { direct[$0] != nil }) else { continue }
                let chain = below
                guard chain.contains(where: { simd_distance(align(ss.joints[$0].position), ts.joints[e].position) > 40 }) else { continue }
                for m in chain {
                    let at = align(ss.joints[m].position)
                    torsoChain[m] = targetTorso.min { simd_distance(at, ts.joints[$0].position) < simd_distance(at, ts.joints[$1].position) }!
                }
            }
        }

        // 4. Move every source vertex and give it target bones.
        let sm = source.mesh
        var out = SkinnedMesh()
        var dominantSource = [Int](repeating: -1, count: sm.positions.count)
        var swapped = Set<Int>()        // vertices of the skin's weapon, put on the champion's weapon bone
        if let weapon {
            for part in sm.parts where weapon.parts.contains(part.name) {
                sm.indices[part.startIndex ..< min(sm.indices.count, part.startIndex + part.indexCount)].forEach { swapped.insert(Int($0)) }
            }
        }
        var heldBy: [Int: Int] = [:]    // vertex → which held weapon (skin weapons put in the champion's hands)
        for (i, h) in held.enumerated() { for v in h.vertices { heldBy[v] = i } }
        let handShift: [Int: SIMD3<Float>] = plan.map { p in
            let d = originalSkeleton.displacements(p)
            return Dictionary(held.map { ($0.hand, d[$0.hand]) }, uniquingKeysWith: { a, _ in a })
        } ?? [:]
        for v in sm.positions.indices {
            if let i = heldBy[v] {
                let h = held[i]
                out.positions.append(h.place(sm.positions[v]) + (handShift[h.hand] ?? .zero))
                out.normals.append(simd_normalize(h.turn.act(sm.normals[v])))
                out.uvs.append(sm.uvs[v])
                out.boneIndices.append(SIMD4(UInt8(clamping: targetInfluence(h.hand)), 0, 0, 0))
                out.weights.append(SIMD4(1, 0, 0, 0))
                continue
            }
            if let weapon, swapped.contains(v) {
                out.positions.append(weapon.place(sm.positions[v]) + weaponShift)
                out.normals.append(simd_normalize(weapon.turn.act(sm.normals[v])))
                out.uvs.append(sm.uvs[v])
                out.boneIndices.append(SIMD4(UInt8(clamping: targetInfluence(weapon.targetJoint)), 0, 0, 0))
                out.weights.append(SIMD4(1, 0, 0, 0))
                continue
            }
            let bones = sm.boneIndices[v], w = sm.weights[v]
            var p = SIMD3<Float>(0, 0, 0), n = SIMD3<Float>(0, 0, 0), total: Float = 0
            var targetWeights: [Int: Float] = [:]
            var best: (Int, Float) = (-1, -1)
            for k in 0 ..< 4 where w[k] > 0 {
                let inf = Int(bones[k])
                let joint = inf < ss.influences.count ? ss.influences[inf] : -1
                guard joint >= 0 && joint < ss.joints.count else { continue }
                if w[k] > best.1 { best = (joint, w[k]) }
                let still = BoneMove(from: align(ss.joints[joint].position), to: align(ss.joints[joint].position))
                let m = torsoChain[joint] != nil ? still : (moveFor(joint) ?? still)
                p += w[k] * m.apply(align(sm.positions[v]))
                n += w[k] * m.rotation.act(sm.normals[v])
                total += w[k]
                targetWeights[targetInfluence(torsoChain[joint] ?? effective[joint] ?? fallbackTarget), default: 0] += w[k]
            }
            dominantSource[v] = best.0
            if total > 0 { p /= total } else { p = align(sm.positions[v]) }
            // Long hair and cloth hanging from the head (veils, ponytails…), which the skin moved with physics: below the
            // neck they follow the upper body instead of swinging with every turn of the head.
            if let head = targetHead, let chest = targetChest, best.0 >= 0, direct[best.0] == nil,
               let w = targetWeights[targetInfluence(head)], p.y < neckHeight {
                let k = min((neckHeight - p.y) / 25, 1) * w
                targetWeights[targetInfluence(head)] = w - k
                targetWeights[targetInfluence(chest), default: 0] += k
            }
            out.positions.append(p)
            out.normals.append(simd_length(n) > 0 ? simd_normalize(n) : sm.normals[v])
            out.uvs.append(sm.uvs[v])
            let top = targetWeights.sorted { $0.value > $1.value }.prefix(4)
            let sum = top.reduce(0) { $0 + $1.value }
            var bi = SIMD4<UInt8>(0, 0, 0, 0), bw = SIMD4<Float>(0, 0, 0, 0)
            for (k, e) in top.enumerated() { bi[k] = UInt8(clamping: e.key); bw[k] = sum > 0 ? e.value / sum : 0 }
            if top.isEmpty { bi[0] = UInt8(clamping: targetInfluence(fallbackTarget)); bw[0] = 1 }
            out.boneIndices.append(bi)
            out.weights.append(bw)
        }

        // 5. Parts: the source's (minus kept regions), then the target's kept pieces.
        let tm = target.mesh
        func dominantTarget(_ v: Int) -> Int {
            let w = tm.weights[v], b = tm.boneIndices[v]
            var best = 0
            for k in 1 ..< 4 where w[k] > w[best] { best = k }
            let inf = Int(b[best])
            return inf < ts.influences.count ? ts.influences[inf] : -1
        }
        let targetPartNames = Set(tm.parts.map(\.name))
        var rename: [String: String] = [:]
        var partTexture: [String: UInt64] = [:]
        for part in sm.parts where !(weapon?.dropped.contains(part.name) ?? false) {
            var tris: [UInt16] = []
            let end = min(sm.indices.count, part.startIndex + part.indexCount)
            var t = part.startIndex
            while t + 2 < end {
                let tri = [sm.indices[t], sm.indices[t + 1], sm.indices[t + 2]]
                if keep.isEmpty || !tri.allSatisfy({ sourceRegion.contains(dominantSource[Int($0)]) }) { tris += tri }
                t += 3
            }
            guard !tris.isEmpty else { continue }
            var name = part.name
            if !keep.isEmpty && targetPartNames.contains(name) { name = "\(sourceName)_\(name)" }
            rename[part.name] = name
            out.parts.append(.init(name: name, startIndex: out.indices.count, indexCount: tris.count))
            out.indices += tris
            if let tex = source.partTexture[part.name] { partTexture[name] = tex }
        }
        var keptTargetTextures: [UInt64] = []
        if !keep.isEmpty {
            let offset = out.positions.count
            guard offset + tm.positions.count <= 65535 else { throw FormatError("The combined model is too big") }
            out.positions += tm.positions
            out.normals += tm.normals
            out.uvs += tm.uvs
            out.boneIndices += tm.boneIndices
            out.weights += tm.weights
            for part in tm.parts {
                var tris: [UInt16] = []
                let end = min(tm.indices.count, part.startIndex + part.indexCount)
                var t = part.startIndex
                while t + 2 < end {
                    let tri = [tm.indices[t], tm.indices[t + 1], tm.indices[t + 2]]
                    if tri.allSatisfy({ targetRegion.contains(dominantTarget(Int($0))) }) { tris += tri.map { UInt16(Int($0) + offset) } }
                    t += 3
                }
                guard !tris.isEmpty else { continue }
                out.parts.append(.init(name: part.name, startIndex: out.indices.count, indexCount: tris.count))
                out.indices += tris
                if let tex = target.partTexture[part.name] {
                    partTexture[part.name] = tex
                    if !keptTargetTextures.contains(tex) { keptTargetTextures.append(tex) }
                }
            }
        }
        guard out.positions.count <= 65535 else { throw FormatError("The model is too big") }

        // Parts whose geometry sits far from the target bone it mostly follows.
        let bodyHeight = max((ts.joints.map(\.position.y).max() ?? 200) - (ts.joints.map(\.position.y).min() ?? 0), 100)
        var farParts: [String] = []
        for part in out.parts where part.indexCount > 0 {
            let verts = Set(out.indices[part.startIndex ..< part.startIndex + part.indexCount].map(Int.init))
            var votes: [Int: Int] = [:]
            var center = SIMD3<Float>(0, 0, 0)
            for v in verts {
                center += out.positions[v]
                let w = out.weights[v], b = out.boneIndices[v]
                var best = 0
                for k in 1 ..< 4 where w[k] > w[best] { best = k }
                let inf = Int(b[best])
                if inf < ts.influences.count { votes[ts.influences[inf], default: 0] += 1 }
            }
            center /= Float(verts.count)
            guard let joint = votes.max(by: { $0.value < $1.value })?.key else { continue }
            if simd_distance(center, ts.joints[joint].position) > max(60, 0.35 * bodyHeight) { farParts.append(part.name) }
        }
        if ProcessInfo.processInfo.environment["SKINLAB_DEBUG"] != nil {
            var groups: [Int: (n: Int, src: SIMD3<Float>, dst: SIMD3<Float>)] = [:]
            for v in sm.positions.indices where dominantSource[v] >= 0 {
                var g = groups[dominantSource[v]] ?? (0, .zero, .zero)
                g.n += 1; g.src += sm.positions[v]; g.dst += out.positions[v]
                groups[dominantSource[v]] = g
            }
            for (j, g) in groups.sorted(by: { $0.value.n > $1.value.n }).prefix(25) {
                let a = g.src / Float(g.n), b = g.dst / Float(g.n)
                print(String(format: "joint %-26@ verts %5d  src %6.0f %6.0f %6.0f -> %6.0f %6.0f %6.0f  move %@", ss.joints[j].name as NSString, g.n,
                             a.x, a.y, a.z, b.x, b.y, b.z, (isTorso(j) ? "torso" : (direct[j] != nil ? "limb" : "follows parent")) as NSString))
            }
            print("hide at start: \(source.hideAtStart)")
            for part in out.parts {
                let idx = out.indices[part.startIndex ..< part.startIndex + part.indexCount].map(Int.init)
                let lo = idx.reduce(SIMD3<Float>(repeating: 1e9)) { simd_min($0, out.positions[$1]) }
                let hi = idx.reduce(SIMD3<Float>(repeating: -1e9)) { simd_max($0, out.positions[$1]) }
                // which source joints dominate this part
                var dom: [String: Int] = [:]
                for v in Set(idx) where v < dominantSource.count && dominantSource[v] >= 0 { dom[ss.joints[dominantSource[v]].name, default: 0] += 1 }
                let top = dom.sorted { $0.value > $1.value }.prefix(3).map { "\($0.key)(\($0.value))" }
                print(String(format: "part %-28@ tris %5d  x %6.0f..%-6.0f y %6.0f..%-6.0f z %6.0f..%-6.0f", part.name as NSString, part.indexCount / 3,
                             lo.x, hi.x, lo.y, hi.y, lo.z, hi.z), top)
            }
        }

        // 6. Textures: the source's become new files of the target skin; kept target ones stay where they are.
        var textures: [UInt64: (data: Data, image: RGBAImage)] = [:]
        var paths: [UInt64: String] = [:]
        var texOrder: [UInt64] = []
        for (i, h) in source.textureOrder.enumerated() {
            guard let t = source.textures[h] else { continue }
            let ext = TextureFile.kind(of: t.data) == .dds ? "dds" : "tex"
            paths[h] = "assets/characters/\(targetName.lowercased())/skins/skinlab/\(sourceName.lowercased())_\(i).\(ext)"
            textures[h] = t
            texOrder.append(h)
        }
        for h in keptTargetTextures where textures[h] == nil {
            if let t = target.textures[h] { textures[h] = t; texOrder.append(h) }
        }
        let hide = source.hideAtStart.compactMap { rename[$0] }
        return PortResult(mesh: out, partTexture: partTexture, newTexturePaths: paths, textures: textures,
                          textureOrder: texOrder, hideAtStart: hide,
                          matchedBones: direct.filter { $0 != nil }.count, sourceBones: ss.joints.count,
                          legPlan: plan, skeleton: plan == nil ? nil : ts,
                          heightRatio: {
                              guard plan != nil, let h = roles(ts).firstIndex(where: { $0?.role == .head }),
                                    ts.joints[h].position.y > 1 else { return 1 }
                              return originalSkeleton.joints[h].position.y / ts.joints[h].position.y
                          }(), farParts: farParts)
    }

    /// The target skin's .bin rewritten to use the ported model and its textures.
    static func editedBin(target: SkinData, sknPath: String, sklPath: String? = nil, sizeFactor: Float = 1,
                          partTexturePath: [String: BinValue], defaultTexture: BinValue?, hide: [String]) -> Data {
        var bin = target.bin
        var props = bin.objects[target.propsIndex]
        var mp = target.meshProps
        let sknValue: BinValue = { if case .file = mp["simpleSkin"] { return .file(pathHash(sknPath)) }; return .string(sknPath) }()
        mp = mp.setting("simpleSkin", sknValue)
        if let sklPath {
            let v: BinValue = { if case .file = mp["skeleton"] { return .file(pathHash(sklPath)) }; return .string(sklPath) }()
            mp = mp.setting("skeleton", v)
        }
        mp = mp.setting("material", nil)
        if sizeFactor != 1 {
            var current: Float = 1
            if case let .raw(0x0A, d)? = mp["skinScale"], d.count == 4 { current = d.withUnsafeBytes { $0.load(as: Float.self) } }
            let bits = (current * sizeFactor).bitPattern
            mp = mp.setting("skinScale", .raw(0x0A, Data((0 ..< 4).map { UInt8((bits >> (8 * UInt32($0))) & 0xFF) })))
        }
        mp = mp.setting("texture", defaultTexture)
        // Extra texture maps of the old model (glow, masks…) would land on the wrong spots: drop them.
        if case let .embed(kind, cls, fields) = mp {
            let keepFiles: Set<UInt32> = [fnv("texture"), fnv("reflectionMap")]
            mp = .embed(kind: kind, cls: cls, fields: fields.filter { f in
                if case .file = f.value { return keepFiles.contains(f.name) }
                return true
            })
        }
        let overrideClass: UInt32 = {
            for o in target.meshProps["materialOverride"]?.items ?? [] { if case let .embed(_, cls, _) = o, cls != 0 { return cls } }
            return fnv("SkinMeshDataProperties_MaterialOverride")
        }()
        let overrides: [BinValue] = partTexturePath.keys.sorted().map { part in
            .embed(kind: 0x83, cls: overrideClass, fields: [
                BinField(name: fnv("texture"), value: partTexturePath[part]!),
                BinField(name: fnv("submesh"), value: .string(part)),
            ])
        }
        mp = mp.setting("materialOverride", overrides.isEmpty ? nil : .list(kind: 0x80, elem: 0x83, overrides))
        mp = mp.setting("initialSubmeshToHide", hide.isEmpty ? nil : .string(hide.joined(separator: ", ")))
        props["skinMeshProperties"] = mp
        bin.objects[target.propsIndex] = props
        return bin.serialized()
    }
}

// MARK: - What to port from

struct PortSource {
    /// nil: the game's own files; otherwise an unpacked mod WAD (file or folder) layered over the game.
    let modWad: URL?
    let champion: String
    let skin: Int
    let label: String

    func open(championsDir: URL) throws -> FileSource {
        let game = try Wad(url: championsDir.appendingPathComponent("\(champion).wad.client"))
        guard let modWad else { return game }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: modWad.path, isDirectory: &isDir)
        let mod: FileSource = isDir.boolValue ? FolderSource(modWad) : try Wad(url: modWad)
        return Layered([mod, game])
    }
}

/// A custom skin file, unpacked so its files can be read.
struct FantomeInfo {
    let name: String
    let champion: String
    /// Made by SkinLab (its description says so): already a finished skin for `champion`.
    var madeBySkinLab = false
    let modWad: URL
    /// Skins of that champion the mod changes.
    let skins: [Int]

    static func inspect(_ url: URL, championsDir: URL) throws -> FantomeInfo {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("SkinLab-mod-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-q", "-o", url.path, "-d", dir.path]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else { throw FormatError("Couldn't open that file") }

        let wadDir = dir.appendingPathComponent("WAD")
        let items = (try? fm.contentsOfDirectory(atPath: wadDir.path)) ?? []
        guard let item = items.first(where: { $0.lowercased().hasSuffix(".wad.client") && $0.split(separator: ".").count == 3 })
            ?? items.first(where: { $0.lowercased().hasSuffix(".wad.client") }) else {
            throw FormatError("No champion files in this mod")
        }
        let modWad = wadDir.appendingPathComponent(item)
        var champion = String(item.split(separator: ".").first ?? "")
        // Use the game's spelling of the champion ("MonkeyKing", not "monkeyking").
        let gameNames = (try? fm.contentsOfDirectory(atPath: championsDir.path)) ?? []
        if let real = gameNames.first(where: { $0.lowercased() == "\(champion.lowercased()).wad.client" }) {
            champion = String(real.dropLast(".wad.client".count))
        }
        var name = url.deletingPathExtension().lastPathComponent
        var madeBySkinLab = false
        if let info = try? Data(contentsOf: dir.appendingPathComponent("META/info.json")),
           let json = try? JSONSerialization.jsonObject(with: info) as? [String: Any] {
            if let n = json["Name"] as? String, !n.isEmpty { name = n }
            madeBySkinLab = (json["Description"] as? String)?.contains("SkinLab") ?? false
        }

        let source = try PortSource(modWad: modWad, champion: champion, skin: 0, label: name).open(championsDir: championsDir)
        let mod = (source as? Layered)?.sources.first
        var skins: [Int] = []
        for n in 0 ..< 200 {
            let h = SkinData.binHash(champion, n)
            if mod?.data(h) != nil { skins.append(n); continue }
            // Mods that only swap the model or textures of an existing skin
            guard let binData = source.data(h), let bin = try? BinFile.parse(binData),
                  let props = bin.objects.first(where: { $0.cls == fnv("SkinCharacterDataProperties") })?["skinMeshProperties"] else { continue }
            let files = [props["simpleSkin"]?.fileHash, props["texture"]?.fileHash].compactMap { $0 }
            if files.contains(where: { mod?.data($0) != nil }) { skins.append(n) }
        }
        return FantomeInfo(name: name, champion: champion, madeBySkinLab: madeBySkinLab, modWad: modWad, skins: skins)
    }
}
