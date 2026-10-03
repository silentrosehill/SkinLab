import Foundation
import simd

/// The champion's weapon replaced by the ported skin's weapon (Gragas's barrel → Gwen's scissors): the new weapon is
/// held the way the skin holds it, and follows the champion's weapon bones, so every animation uses it like the old one.
struct WeaponSwap {
    /// Source model parts that are the weapon (moved onto the champion's weapon bone).
    var parts: [String]
    /// Source parts left out: motion-trail shapes of the weapon, which only make sense with the skin's own effects.
    var dropped: [String]
    /// The champion's weapon joint the new weapon follows.
    var targetJoint: Int
    /// Source rest-pose position → champion rest-pose position, and the turn for normals.
    var turn: simd_quatf
    var offset: SIMD3<Float>
    var scale: Float
    var label: String

    func place(_ p: SIMD3<Float>) -> SIMD3<Float> { offset + scale * turn.act(p) }

    static let words = ["weapon", "sword", "blade", "katana", "scissor", "axe", "hammer", "spear", "lance", "scythe", "staff",
                        "club", "mace", "barrel", "keg", "cask", "whip", "gun", "pistol", "rifle", "cannon", "bow", "guitar"]

    /// A weapon joint by a whole word of its name ("Sword_Blade1", "Scissors_A"; not "L_Elbow" for "bow").
    static func isWeapon(_ name: String) -> Bool {
        let n = name.lowercased()
        guard !n.contains("buffbone"), !n.contains("snap") else { return false }
        return Porter.words(name).contains { t in words.contains { t == $0 || t.hasPrefix($0) && !t.dropFirst($0.count).contains(where: \.isLetter) || t == $0 + "s" } }
    }

    /// Weapon joints (and everything under them) of a skeleton, with how many vertices of a model each one leads.
    private static func weaponJoints(_ sk: Skeleton, _ m: SkinnedMesh) -> (joints: Set<Int>, lead: [Int: Int], dominant: [Int]) {
        var joints = Set<Int>()
        for i in sk.joints.indices where isWeapon(sk.joints[i].name) || joints.contains(sk.joints[i].parent) { joints.insert(i) }
        for i in sk.joints.indices where !joints.contains(i) {    // children listed before their parents
            var p = sk.joints[i].parent
            while p >= 0 { if joints.contains(p) { joints.insert(i); break }; p = sk.joints[p].parent }
        }
        var lead: [Int: Int] = [:]
        var dominant = [Int](repeating: -1, count: m.positions.count)
        for v in m.positions.indices {
            var best = 0
            for k in 1 ..< 4 where m.weights[v][k] > m.weights[v][best] { best = k }
            let inf = Int(m.boneIndices[v][best])
            guard inf < sk.influences.count else { continue }
            dominant[v] = sk.influences[inf]
            if joints.contains(dominant[v]) { lead[dominant[v], default: 0] += 1 }
        }
        return (joints, lead, dominant)
    }

    /// Where a hand holds a weapon, in the weapon joint's rest space: from the animation frame where the hand is closest
    /// to the weapon. Also the hand's rotation then, relative to the weapon joint.
    private static func grip(_ sk: Skeleton, rest: [JointPose], clips: [AnimClip], weapon: Int, hand: Int,
                             points: [SIMD3<Float>]) -> (hand: simd_float4x4, distance: Float)? {
        // A fixed, even sample of the weapon (enough to find the handle).
        let sorted = points.sorted { ($0.x, $0.y, $0.z) < ($1.x, $1.y, $1.z) }
        let probe = stride(from: 0, to: sorted.count, by: max(1, sorted.count / 400)).map { sorted[$0] }
        guard !probe.isEmpty else { return nil }
        let toWeapon = sk.joints[weapon].bind.inverse
        var best: (simd_float4x4, Float)?
        for clip in clips {
            for f in stride(from: 0, to: clip.frameCount, by: max(1, clip.frameCount / 30)) {
                let g = sk.globals(sk.pose(clip, frame: f, rest: rest))
                let m = g[weapon] * toWeapon            // weapon rest space → this frame
                let h = Retarget.position(g[hand])
                let d = probe.map { p -> Float in let w = m * SIMD4(p, 1); return simd_distance(SIMD3(w.x, w.y, w.z), h) }.min() ?? .infinity
                if d < best?.1 ?? .infinity { best = (m.inverse * g[hand], d) }   // the hand, in weapon rest space
            }
        }
        return best
    }

    /// A weapon of the skin put in one of the champion's hands (when the champion has no weapon to swap with):
    /// the vertices that make it, the hand, and where they go (held the way the skin holds it).
    struct Held {
        var vertices: Set<Int>
        var hand: Int               // target joint
        var sourceHand = -1
        var sourceJoint = -1        // the source joint leading the weapon
        var turn: simd_quatf
        var offset: SIMD3<Float>
        var scale: Float
        var name: String
        func place(_ p: SIMD3<Float>) -> SIMD3<Float> { offset + scale * turn.act(p) }
    }

    /// The skin's weapons (each weapon joint group with geometry, like Yone's two swords) put in the champion's hands:
    /// each goes to the hand that holds it in the skin's own animations, in the same grip. Weapons the skin never holds stay.
    static func hold(source: SkinData, sourceClips: [AnimClip], target: SkinData, scale: Float) -> [Held] {
        guard let ss = source.skeleton, let ts = target.skeleton, let sData = source.skeletonData else { return [] }
        let sm = source.mesh
        let s = weaponJoints(ss, sm)
        let sRest = ss.restPoses(sData)
        let sRoles = Porter.roles(ss), tRoles = Porter.roles(ts)
        let height = max((ss.joints.map(\.position.y).max() ?? 200) - (ss.joints.map(\.position.y).min() ?? 0), 100)
        // Groups: a top weapon joint and everything under it.
        var groupOf: [Int: Int] = [:]
        for j in s.joints.sorted() {
            var top = j
            while ss.joints[top].parent >= 0 && s.joints.contains(ss.joints[top].parent) { top = ss.joints[top].parent }
            groupOf[j] = top
        }
        var verts: [Int: Set<Int>] = [:]
        for v in sm.positions.indices { if let g = groupOf[s.dominant[v]] { verts[g, default: []].insert(v) } }
        var out: [Held] = []
        for (top, vs) in verts where vs.count >= 30 {
            let points = vs.sorted().map { sm.positions[$0] }
            var lead: [Int: Int] = [:]
            for v in vs { lead[s.dominant[v], default: 0] += 1 }
            guard let joint = lead.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key })?.key else { continue }
            var best: (side: Character, hand: Int, grip: simd_float4x4, d: Float)?
            // A weapon hanging from a hand in the rig (Zaahen's spear under L_Hand) belongs to that hand.
            var sides: [Character] = ["r", "l"]
            if let h = sRoles.indices.first(where: { sRoles[$0]?.role == .hand && ss.isAncestor($0, of: top) }), let side = sRoles[h]?.side { sides = [side] }
            for side: Character in sides {
                guard let h = sRoles.firstIndex(where: { $0 == Porter.RoleInfo(role: .hand, side: side) }),
                      let g = grip(ss, rest: sRest, clips: sourceClips, weapon: joint, hand: h, points: points) else { continue }
                if g.distance < best?.d ?? .infinity { best = (side, h, g.hand, g.distance) }
            }
            guard let b = best, b.d < height * 0.12,
                  let tHand = tRoles.firstIndex(where: { $0 == Porter.RoleInfo(role: .hand, side: b.side) }) else { continue }
            // p (source rest) → in the source hand (its grip) → the source hand's rest axes → at the champion's hand.
            let turn = simd_normalize(Retarget.rotation(ss.joints[b.hand].bind) * Retarget.rotation(b.grip).inverse)
            let offset = ts.joints[tHand].position - scale * turn.act(Retarget.position(b.grip))
            out.append(Held(vertices: vs, hand: tHand, sourceHand: b.hand, sourceJoint: joint, turn: turn, offset: offset, scale: scale,
                            name: "\(ss.joints[top].name) → \(ts.joints[tHand].name)"))
        }
        return out
    }

    /// One model part of another skin (a weapon) as a model held in the champion's hand: in the hand and grip the skin
    /// uses in its own animations, bound to that hand. Also returns which hand.
    static func heldPart(_ part: String, source: SkinData, sourceClips: [AnimClip], target: SkinData, scale: Float)
        -> (mesh: SkinnedMesh, hand: Int, held: Held)? {
        guard let ts = target.skeleton, let p = source.mesh.parts.first(where: { $0.name == part }) else { return nil }
        let sm = source.mesh
        let end = min(sm.indices.count, p.startIndex + p.indexCount)
        let partVerts = Set(sm.indices[p.startIndex ..< end].map(Int.init))
        // The weapon group (from hold()) that makes most of this part.
        let groups = hold(source: source, sourceClips: sourceClips, target: target, scale: scale)
        guard let g = groups.max(by: { $0.vertices.intersection(partVerts).count < $1.vertices.intersection(partVerts).count }),
              !g.vertices.intersection(partVerts).isEmpty else {
            if ProcessInfo.processInfo.environment["SKINLAB_TEST"] != nil { print("heldPart: no weapon group among", groups.map(\.name), "clips", sourceClips.count) }
            return nil
        }
        let inf = ts.influences.firstIndex(of: g.hand) ?? 0
        var out = SkinnedMesh()
        var newIndex: [Int: Int] = [:]
        for t in stride(from: p.startIndex, to: end - 2, by: 3) {
            let tri = (0 ..< 3).map { Int(sm.indices[t + $0]) }
            for v in tri where newIndex[v] == nil {
                newIndex[v] = out.positions.count
                out.positions.append(g.place(sm.positions[v]))
                out.normals.append(simd_normalize(g.turn.act(sm.normals[v])))
                out.uvs.append(sm.uvs[v])
                out.boneIndices.append(SIMD4(UInt8(clamping: inf), 0, 0, 0))
                out.weights.append(SIMD4(1, 0, 0, 0))
            }
            out.indices += tri.map { UInt16(newIndex[$0]!) }
        }
        out.parts = [.init(name: part, startIndex: 0, indexCount: out.indices.count)]
        return (out, g.hand, g)
    }

    /// The track of a weapon bone hanging from the target hand (at the hand in the rest pose) that moves the weapon as the
    /// source skin moves it, frame by frame: relative to the hand, turned into the target hand's axes and scaled.
    /// `source(f)` / `target(f)` give both skeletons' local poses at output frame f.
    static func weaponTrack(_ held: Held, frames: Int, source ss: Skeleton, sourceAt: (Int) -> [JointPose],
                            target ts: Skeleton, targetAt: (Int) -> [JointPose]) -> [JointPose] {
        let sw = held.sourceJoint, sh = held.sourceHand, th = held.hand
        guard sw >= 0, sh >= 0 else { return [] }
        let toSourceRest = ss.joints[sw].bind.inverse
        let x = Retarget.rotation(ts.joints[th].bind).inverse * Retarget.rotation(ss.joints[sh].bind)
        let handBind = ts.joints[th].bind
        return (0 ..< frames).map { f in
            let sG = ss.globals(sourceAt(f)), tG = ts.globals(targetAt(f))
            let m = sG[sw] * toSourceRest
            let rs = Retarget.rotation(m), tsv = Retarget.position(m)
            let k = Retarget.rotation(tG[th]) * x * Retarget.rotation(sG[sh]).inverse
            let rm = simd_normalize(k * rs * held.turn.inverse)
            let tm = Retarget.position(tG[th]) + held.scale * k.act(tsv - Retarget.position(sG[sh])) - rm.act(held.offset)
            var world = simd_float4x4(rm)
            world.columns.3 = SIMD4(tm, 1)
            let local = tG[th].inverse * (world * handBind)
            return JointPose(rotation: Retarget.rotation(local), translation: Retarget.position(local), scale: SIMD3(repeating: 1))
        }
    }

    /// Plans the swap, or nil when the champion has no weapon in its model or the skin has none to give.
    static func plan(source: SkinData, sourceClips: [AnimClip], target: SkinData, targetClips: [AnimClip], scale: Float) -> WeaponSwap? {
        guard let ss = source.skeleton, let ts = target.skeleton, let sData = source.skeletonData, let tData = target.skeletonData else { return nil }
        let sm = source.mesh, tm = target.mesh
        let s = weaponJoints(ss, sm), t = weaponJoints(ts, tm)
        // The champion's weapon: the weapon joint leading the most of its model.
        guard let tJoint = t.lead.max(by: { $0.value < $1.value }), tJoint.value >= 20 else { return nil }
        // The skin's weapon: its parts mostly made of weapon joints.
        var parts: [String] = [], dropped: [String] = []
        for part in sm.parts {
            let end = min(sm.indices.count, part.startIndex + part.indexCount)
            let verts = Set(sm.indices[part.startIndex ..< end].map(Int.init))
            let onWeapon = verts.filter { s.joints.contains(s.dominant[$0]) }.count
            guard verts.count > 0, Float(onWeapon) / Float(verts.count) > 0.6 else { continue }
            let n = part.name.lowercased()
            if ["smear", "trail", "swipe", "fx", "glow"].contains(where: { n.contains($0) }) { dropped.append(part.name) } else { parts.append(part.name) }
        }
        guard !parts.isEmpty else { return nil }
        var sVerts = Set<Int>()
        for part in sm.parts where parts.contains(part.name) {
            sm.indices[part.startIndex ..< min(sm.indices.count, part.startIndex + part.indexCount)].forEach { sVerts.insert(Int($0)) }
        }
        var sLead: [Int: Int] = [:]
        for v in sVerts where s.joints.contains(s.dominant[v]) { sLead[s.dominant[v], default: 0] += 1 }
        guard let sJoint = sLead.max(by: { $0.value < $1.value })?.key else { return nil }

        // Which hand holds each weapon (closest in their own animations), and how.
        let sRoles = Porter.roles(ss), tRoles = Porter.roles(ts)
        let sPoints = sVerts.map { sm.positions[$0] }
        let tPoints = tm.positions.indices.filter { t.dominant[$0] == tJoint.key }.map { tm.positions[$0] }
        let sRest = ss.restPoses(sData), tRest = ts.restPoses(tData)
        func held(_ sk: Skeleton, _ roles: [Porter.RoleInfo?], rest: [JointPose], clips: [AnimClip], weapon: Int, points: [SIMD3<Float>])
            -> (hand: Int, grip: simd_float4x4)? {
            var best: (Int, simd_float4x4, Float)?
            for side: Character in ["r", "l"] {
                guard let h = roles.firstIndex(where: { $0 == Porter.RoleInfo(role: .hand, side: side) }),
                      let g = grip(sk, rest: rest, clips: clips, weapon: weapon, hand: h, points: points) else { continue }
                if g.distance < best?.2 ?? .infinity { best = (h, g.hand, g.distance) }
            }
            return best.map { ($0.0, $0.1) }
        }
        guard let sHeld = held(ss, sRoles, rest: sRest, clips: sourceClips, weapon: sJoint, points: sPoints),
              let tHeld = held(ts, tRoles, rest: tRest, clips: targetClips, weapon: tJoint.key, points: tPoints) else { return nil }

        // The weapon, seen from the source hand (in the source's rest space); the hand turned into the target rig's hand axes
        // (both rigs' hands point the same way in their rest poses); then placed in the target hand's grip of its own weapon.
        let sHandRest = Retarget.rotation(ss.joints[sHeld.hand].bind), tHandRest = Retarget.rotation(ts.joints[tHeld.hand].bind)
        let axes = tHandRest.inverse * sHandRest                    // source hand axes → target hand axes
        let sGripTurn = Retarget.rotation(sHeld.grip), tGripTurn = Retarget.rotation(tHeld.grip)
        let sGripPos = Retarget.position(sHeld.grip), tGripPos = Retarget.position(tHeld.grip)
        // p (source rest) → in source hand space → target hand space → target weapon rest space
        let turn = simd_normalize(tGripTurn * axes * sGripTurn.inverse)
        let offset = tGripPos - scale * turn.act(sGripPos)
        return WeaponSwap(parts: parts, dropped: dropped, targetJoint: tJoint.key, turn: turn, offset: offset, scale: scale,
                          label: "\(parts.joined(separator: ", ")) → \(ts.joints[tJoint.key].name)")
    }
}
