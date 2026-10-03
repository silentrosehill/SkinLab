import Foundation
import simd

/// Moving animations and held items from one champion's skeleton to another's.
enum Retarget {
    static func rotation(_ m: simd_float4x4) -> simd_quatf {
        let c0 = simd_normalize(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z))
        let c1 = simd_normalize(SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z))
        let c2 = simd_normalize(SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
        return simd_normalize(simd_quatf(simd_float3x3(c0, c1, c2)))
    }

    static func position(_ m: simd_float4x4) -> SIMD3<Float> { SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z) }

    /// For each target joint, the source joint whose movement it copies (same name first, then same body part).
    static func drivers(source ss: Skeleton, target ts: Skeleton) -> [Int?] {
        let direct = Porter.matchJoints(ss, ts)
        var best: [Int: Int] = [:]
        for (s, t) in direct.enumerated() {
            guard let t else { continue }
            let exact = ss.joints[s].name.lowercased() == ts.joints[t].name.lowercased()
            if let cur = best[t] {
                let curExact = ss.joints[cur].name.lowercased() == ts.joints[t].name.lowercased()
                if exact && !curExact { best[t] = s }
            } else {
                best[t] = s
            }
        }
        return ts.joints.indices.map { best[$0] }
    }

    private static func topological(_ sk: Skeleton) -> [Int] {
        var order: [Int] = [], seen = Set<Int>()
        func visit(_ j: Int) {
            guard !seen.contains(j) else { return }
            seen.insert(j)
            let p = sk.joints[j].parent
            if p >= 0 && p < sk.joints.count { visit(p) }
            order.append(j)
        }
        sk.joints.indices.forEach(visit)
        return order
    }

    /// The source animation played by the target skeleton: every joint turns the way its source joint turns
    /// (measured from each skeleton's own rest pose, so different bone orientations don't matter), bones keep the
    /// target's lengths, and the body moves like the source's pelvis, scaled to the target's leg length.
    static func clip(_ src: AnimClip, source ss: Skeleton, sourceRest: [JointPose], target ts: Skeleton, targetRest: [JointPose]) -> AnimClip {
        let drive = drivers(source: ss, target: ts)
        let sRestG = ss.globals(sourceRest), tRestG = ts.globals(targetRest)
        let sRestR = sRestG.map(rotation), tRestR = tRestG.map(rotation)
        let sRoles = Porter.roles(ss), tRoles = Porter.roles(ts)
        let sPelvis = sRoles.firstIndex { $0?.role == .pelvis }
        let tPelvis = tRoles.firstIndex { $0?.role == .pelvis }
        let tRoot = bodyRoot(ts)
        var k: Float = 1
        if let sp = sPelvis, let tp = tPelvis, position(sRestG[sp]).y > 1 { k = position(tRestG[tp]).y / position(sRestG[sp]).y }
        let order = topological(ts)

        var tracks: [UInt32: [JointPose]] = [:]
        for j in ts.joints.indices { tracks[ts.joints[j].nameHash] = [] }
        for f in 0 ..< src.frameCount {
            let sG = ss.globals(ss.pose(src, frame: f, rest: sourceRest))
            var tR = [simd_quatf](repeating: simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)), count: ts.joints.count)
            for j in order {
                let p = ts.joints[j].parent
                if let s = drive[j] {
                    tR[j] = simd_normalize(rotation(sG[s]) * sRestR[s].inverse * tRestR[j])
                } else {
                    tR[j] = simd_normalize((p >= 0 ? tR[p] : simd_quatf(angle: 0, axis: SIMD3(0, 1, 0))) * targetRest[j].rotation)
                }
            }
            for j in ts.joints.indices {
                let p = ts.joints[j].parent
                let local = p >= 0 ? simd_normalize(tR[p].inverse * tR[j]) : tR[j]
                var t = targetRest[j].translation
                if j == tRoot, let sp = sPelvis {
                    t = position(tRestG[tRoot]) + k * (position(sG[sp]) - position(sRestG[sp]))
                }
                tracks[ts.joints[j].nameHash]!.append(JointPose(rotation: local, translation: t, scale: targetRest[j].scale))
            }
        }
        return AnimClip(fps: src.fps, frameCount: src.frameCount, tracks: tracks)
    }

    /// A held item (a model part following hand/weapon bones) taken from the moment of an animation where it sits
    /// closest to the hand, and fixed in the target's hand in that grip.
    static func holdInHand(part name: String, source: SkinData, clip: AnimClip, sourceRest: [JointPose],
                           target ts: Skeleton, targetRest: [JointPose], scale: Float) -> SkinnedMesh? {
        guard let ss = source.skeleton, let part = source.mesh.parts.first(where: { $0.name == name }) else { return nil }
        let sRoles = Porter.roles(ss), tRoles = Porter.roles(ts)
        guard let sHand = sRoles.firstIndex(where: { $0 == Porter.RoleInfo(role: .hand, side: "r") }),
              let tHand = tRoles.firstIndex(where: { $0 == Porter.RoleInfo(role: .hand, side: "r") }),
              let handInfluence = ts.influences.firstIndex(of: tHand) ?? ts.influences.indices.first else { return nil }
        let m = source.mesh
        let end = min(m.indices.count, part.startIndex + part.indexCount)
        let tris = Array(m.indices[part.startIndex ..< end]).map(Int.init)
        let verts = Array(Set(tris)).sorted()
        guard !verts.isEmpty else { return nil }
        let skin = ss.joints.indices.map { ss.joints[$0].bind.inverse }

        func world(_ g: [simd_float4x4], _ v: Int, normal: Bool = false) -> SIMD3<Float> {
            var out = SIMD4<Float>(0, 0, 0, 0)
            let input = normal ? SIMD4(m.normals[v], 0) : SIMD4(m.positions[v], 1)
            for k in 0 ..< 4 where m.weights[v][k] > 0 {
                let inf = Int(m.boneIndices[v][k])
                guard inf < ss.influences.count else { continue }
                let j = ss.influences[inf]
                out += m.weights[v][k] * (g[j] * skin[j] * input)
            }
            return SIMD3(out.x, out.y, out.z)
        }
        // The frame where the item is closest to the hand.
        let probe = stride(from: 0, to: verts.count, by: max(1, verts.count / 40)).map { verts[$0] }
        var bestFrame = 0, bestDistance = Float.greatestFiniteMagnitude
        for f in 0 ..< clip.frameCount {
            let g = ss.globals(ss.pose(clip, frame: f, rest: sourceRest))
            let center = probe.reduce(SIMD3<Float>(0, 0, 0)) { $0 + world(g, $1) } / Float(probe.count)
            let d = simd_distance(center, position(g[sHand]))
            if d < bestDistance { bestDistance = d; bestFrame = f }
        }
        let g = ss.globals(ss.pose(clip, frame: bestFrame, rest: sourceRest))
        let sRestG = ss.globals(sourceRest), tRestG = ts.globals(targetRest)
        let handInv = g[sHand].inverse
        let restTurn = rotation(sRestG[sHand])
        let handPos = position(tRestG[tHand])

        var out = SkinnedMesh()
        var newIndex: [Int: Int] = [:]
        for v in verts {
            let local = handInv * SIMD4(world(g, v), 1)
            out.positions.append(handPos + scale * restTurn.act(SIMD3(local.x, local.y, local.z)))
            let n = handInv * SIMD4(world(g, v, normal: true), 0)
            let rn = restTurn.act(SIMD3(n.x, n.y, n.z))
            out.normals.append(simd_length(rn) > 0 ? simd_normalize(rn) : SIMD3(0, 1, 0))
            out.uvs.append(m.uvs[v])
            out.boneIndices.append(SIMD4(UInt8(clamping: handInfluence), 0, 0, 0))
            out.weights.append(SIMD4(1, 0, 0, 0))
            newIndex[v] = out.positions.count - 1
        }
        out.indices = tris.map { UInt16(newIndex[$0]!) }
        out.parts = [.init(name: name, startIndex: 0, indexCount: out.indices.count)]
        return out
    }

    /// The top joint the body hangs from ("Root"): what moves and turns the whole character in an animation.
    static func bodyRoot(_ sk: Skeleton) -> Int {
        var j = Porter.roles(sk).firstIndex { $0?.role == .pelvis } ?? 0
        while sk.joints[j].parent >= 0 { j = sk.joints[j].parent }
        return j
    }

    /// How much the source character was scaled to fit the target (torso length ratio, as when porting).
    static func bodyScale(source ss: Skeleton, target ts: Skeleton) -> Float {
        let sr = Porter.roles(ss), tr = Porter.roles(ts)
        guard let sp = sr.firstIndex(where: { $0?.role == .pelvis }), let sh = sr.firstIndex(where: { $0?.role == .head }),
              let tp = tr.firstIndex(where: { $0?.role == .pelvis }), let th = tr.firstIndex(where: { $0?.role == .head }) else { return 1 }
        let s = simd_distance(ss.joints[sp].position, ss.joints[sh].position)
        return s > 1 ? simd_distance(ts.joints[tp].position, ts.joints[th].position) / s : 1
    }
}

// MARK: - Show/hide events in an animation graph

enum GraphEdit {
    struct PartEvent {
        let name: String          // event name (unique within the clip)
        let frame: Float?
        let show: [String]
        let hide: [String]
        /// Also happens if the animation is cut short (by moving, another spell…), like Riot's own "put away" events.
        var evenIfCutShort = false
    }

    static func eventValue(_ e: PartEvent) -> (BinValue, BinValue) {
        var fields = [BinField(name: fnv("mName"), value: .hash(fnv(e.name)))]
        if let f = e.frame, f > 0 {
            let b = f.bitPattern
            fields.append(BinField(name: fnv("mStartFrame"), value: .raw(0x0A, Data((0 ..< 4).map { UInt8((b >> (8 * UInt32($0))) & 0xFF) }))))
        }
        if e.evenIfCutShort { fields.append(BinField(name: fnv("mFireIfAnimationEndsEarly"), value: .raw(0x01, Data([1])))) }
        if !e.show.isEmpty {
            fields.append(BinField(name: fnv("mShowSubmeshList"), value: .list(kind: 0x80, elem: 0x11, e.show.map { .hash(fnv($0)) })))
        }
        if !e.hide.isEmpty {
            fields.append(BinField(name: fnv("mHideSubmeshList"), value: .list(kind: 0x80, elem: 0x11, e.hide.map { .hash(fnv($0)) })))
        }
        return (.hash(fnv(e.name)), .embed(kind: 0x82, cls: fnv("SubmeshVisibilityEventData"), fields: fields))
    }

    /// The animation graph with clips pointed at new animation files (by path) and events added.
    static func edited(_ bin: BinFile, files: [UInt32: String], events: [UInt32: [PartEvent]]) -> BinFile {
        var out = bin
        for i in out.objects.indices where out.objects[i].cls == fnv("AnimationGraphData") {
            guard case let .map(k, v, entries)? = out.objects[i]["mClipDataMap"] else { continue }
            let newEntries: [(BinValue, BinValue)] = entries.map { key, clip in
                guard case let .hash(name) = key else { return (key, clip) }
                var c = clip
                if let path = files[name], let res = c["mAnimationResourceData"] {
                    let value: BinValue = { if case .string = res["mAnimationFilePath"] { return .string(path) }; return .file(pathHash(path)) }()
                    c = c.setting("mAnimationResourceData", res.setting("mAnimationFilePath", value))
                }
                if let add = events[name], !add.isEmpty {
                    var list: [(BinValue, BinValue)] = []
                    var mk: UInt8 = 0x11, mv: UInt8 = 0x82
                    if case let .map(ek, ev, existing)? = c["mEventDataMap"] { list = existing; mk = ek; mv = ev }
                    list += add.map(eventValue)
                    c = c.setting("mEventDataMap", .map(key: mk, val: mv, list))
                }
                return (key, c)
            }
            out.objects[i]["mClipDataMap"] = .map(key: k, val: v, newEntries)
        }
        return out
    }
}
