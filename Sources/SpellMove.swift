import Foundation
import simd

/// A borrowed attack animation turned into a spell's animation: timed so its blow lands when the spell hits,
/// turned for the spell's direction variants, and eased back to idle afterwards.
enum SpellMove {
    // MARK: Sampling between frames

    static func mix(_ a: JointPose, _ b: JointPose, _ t: Float) -> JointPose {
        JointPose(rotation: simd_slerp(a.rotation, b.rotation, t), translation: a.translation + (b.translation - a.translation) * t,
                  scale: a.scale + (b.scale - a.scale) * t)
    }

    static func pose(_ clip: AnimClip, _ joint: UInt32, at frame: Float) -> JointPose? {
        guard let track = clip.tracks[joint], !track.isEmpty else { return nil }
        let f = min(max(frame, 0), Float(track.count - 1))
        let i = Int(f.rounded(.down))
        return mix(track[i], track[min(i + 1, track.count - 1)], f - Float(i))
    }

    /// A clip of `frameCount` frames whose frame n shows `clip` at frame `time(n)`.
    static func retimed(_ clip: AnimClip, frameCount: Int, _ time: (Int) -> Float) -> AnimClip {
        let times = (0 ..< frameCount).map(time)
        var out = AnimClip(fps: clip.fps, frameCount: frameCount, tracks: [:])
        for h in clip.tracks.keys { out.tracks[h] = times.map { pose(clip, h, at: $0)! } }
        return out
    }

    // MARK: Timing

    /// When an animation's blow lands: the moment its body moves fastest (in frames, between two frames).
    static func impactFrame(_ clip: AnimClip, skeleton sk: Skeleton, rest: [JointPose]) -> Float {
        var previous: [SIMD3<Float>]?
        var best: (frame: Float, speed: Float) = (Float(clip.frameCount) / 2, -1)
        for f in 0 ..< clip.frameCount {
            let p = sk.globals(sk.pose(clip, frame: f, rest: rest)).map(Retarget.position)
            if let previous {
                let speed = zip(p, previous).reduce(Float(0)) { $0 + simd_distance($1.0, $1.1) }
                if speed > best.speed { best = (Float(f) - 0.5, speed) }
            }
            previous = p
        }
        return best.frame
    }

    /// A swing of a held weapon: where it is at each frame (tip and hilt, model space) and the body's center.
    struct Path {
        var tip: [SIMD3<Float>] = []
        var hilt: [SIMD3<Float>] = []
        var hand: [SIMD3<Float>] = []
        var center: [SIMD3<Float>] = []
        let fps: Float

        /// Left (−) / right (+) angle of the tip around the body, 0 straight ahead (+Z), in degrees.
        func angle(_ f: Int) -> Float {
            let d = tip[f] - center[f]
            return atan2(d.x, d.z) * 180 / .pi
        }
        func speed(_ f: Int) -> Float { f > 0 ? simd_distance(tip[f], tip[f - 1]) * fps : 0 }

        /// The fast part: from the frame the weapon starts moving fast to the frame it slows down.
        var swing: ClosedRange<Int>? {
            guard tip.count > 2 else { return nil }
            let speeds = tip.indices.map(speed)
            guard let top = speeds.max(), top > 0, let peak = speeds.firstIndex(of: top) else { return nil }
            var a = peak, b = peak
            while a > 1 && speeds[a - 1] > top * 0.35 { a -= 1 }
            while b < speeds.count - 1 && speeds[b + 1] > top * 0.35 { b += 1 }
            return (a - 1) ... b
        }

        /// The swing's angles around the body, unwrapped (so a sweep through the back keeps counting).
        func sweep(_ r: ClosedRange<Int>) -> [Float] {
            var out: [Float] = []
            for f in r {
                var a = angle(f)
                if let last = out.last { while a - last > 180 { a -= 360 }; while a - last < -180 { a += 360 } }
                out.append(a)
            }
            return out
        }

        /// The moment the blade passes in front of the body during the swing (or its fastest moment).
        var strike: Float? {
            guard let r = swing else { return nil }
            let a = sweep(r)
            for i in 0 ..< a.count - 1 where (a[i] <= 0) != (a[i + 1] <= 0) && abs(a[i + 1] - a[i]) < 180 {
                return Float(r.lowerBound + i) + a[i] / (a[i] - a[i + 1])
            }
            let speeds = r.map(speed)
            return Float(r.lowerBound + (speeds.firstIndex(of: speeds.max() ?? 0) ?? 0)) - 0.5
        }
    }

    /// The weapon's path through an animation: `weapon` is a model part skinned to the hand (as SkinLab puts it there).
    static func path(_ clip: AnimClip, skeleton sk: Skeleton, rest: [JointPose], weapon: SkinnedMesh) -> Path? {
        guard let inf = weapon.boneIndices.first.map({ Int($0[0]) }), inf < sk.influences.count else { return nil }
        let hand = sk.influences[inf]
        let handRest = sk.joints[hand].position
        guard let tip = weapon.positions.max(by: { simd_distance($0, handRest) < simd_distance($1, handRest) }),
              let hilt = weapon.positions.min(by: { simd_distance($0, handRest) < simd_distance($1, handRest) }) else { return nil }
        let toHand = sk.joints[hand].bind.inverse
        var root = sk.index(named: "Pelvis") ?? 0
        if let r = Porter.roles(sk).firstIndex(where: { $0?.role == .pelvis }) { root = r }
        var p = Path(fps: clip.fps)
        for f in 0 ..< clip.frameCount {
            let g = sk.globals(sk.pose(clip, frame: f, rest: rest))
            let m = g[hand] * toHand
            let t = m * SIMD4(tip, 1), h = m * SIMD4(hilt, 1)
            p.tip.append(SIMD3(t.x, t.y, t.z))
            p.hilt.append(SIMD3(h.x, h.y, h.z))
            p.hand.append(Retarget.position(g[hand]))
            p.center.append(Retarget.position(g[root]))
        }
        return p
    }

    /// The path of a weapon part through one of its own skin's animations (before porting): its blade's two ends,
    /// the tip being the one away from the right hand.
    static func path(_ clip: AnimClip, source: SkinData, part name: String, rest: [JointPose]) -> Path? {
        guard let sk = source.skeleton, let part = source.mesh.parts.first(where: { $0.name == name }) else { return nil }
        let m = source.mesh
        let end = min(m.indices.count, part.startIndex + part.indexCount)
        let verts = Array(Set(m.indices[part.startIndex ..< end].map(Int.init))).sorted()
        let roles = Porter.roles(sk)
        guard verts.count > 1, let hand = roles.firstIndex(where: { $0 == Porter.RoleInfo(role: .hand, side: "r") }) else { return nil }
        let center = roles.firstIndex { $0?.role == .pelvis } ?? 0
        let sample = stride(from: 0, to: verts.count, by: max(1, verts.count / 200)).map { verts[$0] }
        var ends = (sample[0], sample[0]), longest: Float = -1
        for a in sample { for b in sample { let d = simd_distance(m.positions[a], m.positions[b]); if d > longest { longest = d; ends = (a, b) } } }
        let skin = sk.joints.indices.map { sk.joints[$0].bind.inverse }
        func world(_ g: [simd_float4x4], _ v: Int) -> SIMD3<Float> {
            var out = SIMD4<Float>(0, 0, 0, 0)
            for k in 0 ..< 4 where m.weights[v][k] > 0 {
                let inf = Int(m.boneIndices[v][k])
                guard inf < sk.influences.count else { continue }
                let j = sk.influences[inf]
                out += m.weights[v][k] * (g[j] * skin[j] * SIMD4(m.positions[v], 1))
            }
            return SIMD3(out.x, out.y, out.z)
        }
        var p = Path(fps: clip.fps)
        for f in 0 ..< clip.frameCount {
            let g = sk.globals(sk.pose(clip, frame: f, rest: rest))
            var a = world(g, ends.0), b = world(g, ends.1)
            let h = Retarget.position(g[hand])
            if simd_distance(a, h) < simd_distance(b, h) { swap(&a, &b) }
            p.tip.append(a)
            p.hilt.append(b)
            p.hand.append(h)
            p.center.append(Retarget.position(g[center]))
        }
        return p
    }

    /// How well an animation works as a slash from the left to the right in front of the body (nil: not one).
    static func leftToRightScore(_ p: Path, height: Float) -> Float? {
        guard let r = p.swing, let strike = p.strike else { return nil }
        // A real swing: fast, with the weapon in the hand.
        guard r.map(p.speed).max() ?? 0 > height * 8 else { return nil }
        let blade = r.map { simd_distance(p.tip[$0], p.hilt[$0]) }.reduce(0, +) / Float(r.count)
        let grip = r.map { simd_distance(p.hilt[$0], p.hand[$0]) }.reduce(0, +) / Float(r.count)
        guard grip < max(blade * 0.35, height * 0.15) else { return nil }
        let a = p.sweep(r)
        guard let first = a.first, let last = a.last else { return nil }
        let turn = last - first
        guard turn > 60, turn < 300, first < -10, last > 10 else { return nil }
        let i = min(max(Int(strike.rounded()), 0), p.tip.count - 1)
        let tipHeight = p.tip[i].y / max(height, 1)
        guard tipHeight > 0.15, tipHeight < 1.4 else { return nil }
        let heights = r.map { p.tip[$0].y }
        let rise = ((heights.max() ?? 0) - (heights.min() ?? 0)) / max(height, 1)
        let level = 1 - min(abs(tipHeight - 0.75), 0.6)          // best around the waist and chest
        return min(turn, 220) / 220 + level - rise * 0.6
    }

    /// The borrowed swing slowed down before it (a held stance), so that its blade passes in front of the body
    /// at `hitAt`, and played at its own speed from the start of the swing on.
    static func timed(_ clip: AnimClip, path: Path, hitAt: Float, frameCount: Int) -> AnimClip {
        guard let r = path.swing, let strike = path.strike else { return clip }
        let start = Float(r.lowerBound)
        let swingStart = max(hitAt - (strike - start), 1)        // when the swing begins in the new clip
        let last = Float(clip.frameCount - 1)
        return retimed(clip, frameCount: frameCount) { n in
            let t = Float(n)
            if t <= swingStart {
                let x = t / swingStart
                return start * x * x * (3 - 2 * x)               // ease into the stance and hold it
            }
            return min(start + (t - swingStart), last)
        }
    }

    /// A whole animation made for the spell (e.g. another skin's own W) nudged so its blow lands at `hitAt`:
    /// everything before the blow is stretched or squeezed evenly, the blow and what follows keep their speed.
    static func shifted(_ clip: AnimClip, strike: Float, hitAt: Float) -> AnimClip {
        guard strike > 1, abs(hitAt - strike) > 0.25 else { return clip }
        let shift = hitAt - strike
        let count = max(2, clip.frameCount + Int(shift.rounded()))
        return retimed(clip, frameCount: count) { n in
            let t = Float(n)
            return t <= hitAt ? t * strike / hitAt : min(t - shift, Float(clip.frameCount - 1))
        }
    }

    /// The held stance comes alive: the upper body slowly winds further away from the swing while it waits,
    /// and springs back during the swing (which gets a snap). `degrees` is the wind-up at its fullest.
    static func woundUp(_ clip: AnimClip, path: Path, skeleton sk: Skeleton, rest: [JointPose], hitAt: Float, degrees: Float = 15) -> AnimClip {
        guard let r = path.swing, let strike = path.strike else { return clip }
        let roles = Porter.roles(sk)
        let spine = sk.joints.indices.filter { roles[$0]?.role == .spine }
        let sweep = path.sweep(r)
        guard !spine.isEmpty, let first = sweep.first, let last = sweep.last, first != last else { return clip }
        // Away from the swing: a slash to the right winds up to the left (and the other way round).
        let away = (last > first ? -degrees : degrees) * .pi / 180
        let swingStart = max(hitAt - (strike - Float(r.lowerBound)), 1)
        var out = clip
        for f in 0 ..< clip.frameCount {
            let t = Float(f)
            var w: Float = 0
            if t <= swingStart {
                let x = t / swingStart
                w = x * x * (3 - 2 * x)
            } else if t < hitAt {
                let x = (t - swingStart) / max(hitAt - swingStart, 0.001)
                w = 1 - x * x * (3 - 2 * x)
            }
            guard w > 0 else { continue }
            let local = sk.pose(clip, frame: f, rest: rest)
            let g = sk.globals(local)
            let turn = simd_quatf(angle: away * w / Float(spine.count), axis: SIMD3(0, 1, 0))
            // Each spine joint turned around the vertical: in its parent's space, so the turns add up up the spine.
            for j in spine {
                let p = sk.joints[j].parent
                let parent = p >= 0 ? Retarget.rotation(g[p]) : simd_quatf(angle: 0, axis: SIMD3(0, 1, 0))
                guard out.tracks[sk.joints[j].nameHash] != nil else { continue }
                out.tracks[sk.joints[j].nameHash]![f].rotation = simd_normalize(parent.inverse * turn * parent * local[j].rotation)
            }
        }
        return out
    }

    /// The whole body turned around the vertical axis (how the game's direction variants like "Spell2_90" are made).
    static func turned(_ clip: AnimClip, degrees: Float, bodyRoot: UInt32) -> AnimClip {
        guard degrees != 0, let track = clip.tracks[bodyRoot] else { return clip }
        let q = simd_quatf(angle: degrees * .pi / 180, axis: SIMD3(0, 1, 0))
        var out = clip
        out.tracks[bodyRoot] = track.map { JointPose(rotation: simd_normalize(q * $0.rotation), translation: q.act($0.translation), scale: $0.scale) }
        return out
    }

    /// From one pose to another, eased (e.g. back to idle after the spell).
    static func settle(from a: [UInt32: JointPose], to b: [UInt32: JointPose], frameCount: Int, fps: Float) -> AnimClip {
        var out = AnimClip(fps: fps, frameCount: frameCount, tracks: [:])
        for h in Set(a.keys).union(b.keys) {
            let p0 = a[h] ?? b[h]!, p1 = b[h] ?? a[h]!
            out.tracks[h] = (0 ..< frameCount).map { n in
                let x = frameCount > 1 ? Float(n) / Float(frameCount - 1) : 1
                return mix(p0, p1, x * x * (3 - 2 * x))
            }
        }
        return out
    }

    /// `base` with some joints (e.g. the arms) moving as in `other`: matched by cycle position (runs), or by time
    /// looped over `other` (idles). How a champion carries a weapon while idle and running.
    static func blended(_ base: AnimClip, joints: Set<UInt32>, from other: AnimClip, byCycle: Bool) -> AnimClip {
        var out = base
        let n = base.frameCount
        guard n > 0, other.frameCount > 0 else { return base }
        for h in joints {
            guard other.tracks[h] != nil else { continue }
            out.tracks[h] = (0 ..< n).map { f in pose(other, h, at: otherFrame(f, of: base, in: other, byCycle: byCycle))! }
        }
        return out
    }

    /// `base` with some joints (the arms) pointing the way they point in `other`, in the world: so they keep their pose
    /// whatever the base body does (a leaning, twisting run doesn't swing them around). Bone lengths stay the base's.
    static func blendedWorld(_ base: AnimClip, joints: Set<UInt32>, from other: AnimClip, byCycle: Bool,
                             skeleton sk: Skeleton, rest: [JointPose]) -> AnimClip {
        var out = base
        func depth(_ j: Int) -> Int { var d = 0, p = sk.joints[j].parent; while p >= 0 { d += 1; p = sk.joints[p].parent }; return d }
        let order = sk.joints.indices.filter { joints.contains(sk.joints[$0].nameHash) }.sorted { depth($0) < depth($1) }
        var tracks: [Int: [JointPose]] = [:]
        for f in 0 ..< base.frameCount {
            var local = sk.pose(base, frame: f, rest: rest)
            let g = sk.globals(local)
            let target = sk.globals(poses(other, sk, rest: rest, at: otherFrame(f, of: base, in: other, byCycle: byCycle)))
            var world: [Int: simd_float4x4] = [:]
            for j in order {
                let p = sk.joints[j].parent
                let parent = p >= 0 ? (world[p] ?? g[p]) : matrix_identity_float4x4
                local[j].rotation = simd_normalize(Retarget.rotation(parent).inverse * Retarget.rotation(target[j]))
                world[j] = parent * local[j].matrix
                tracks[j, default: []].append(local[j])
            }
        }
        for (j, t) in tracks { out.tracks[sk.joints[j].nameHash] = t }
        return out
    }

    /// Which frame of `other` goes with frame f of `base` (see blended()).
    static func otherFrame(_ f: Int, of base: AnimClip, in other: AnimClip, byCycle: Bool) -> Float {
        let n = base.frameCount
        if byCycle { return n > 1 ? Float(f) / Float(n - 1) * Float(other.frameCount - 1) : 0 }
        let secs = Float(f) / base.fps
        return (secs * other.fps).truncatingRemainder(dividingBy: Float(max(other.frameCount - 1, 1)))
    }

    /// All joints' local poses of a clip at a (fractional) frame, rest pose for joints it doesn't move.
    static func poses(_ clip: AnimClip, _ sk: Skeleton, rest: [JointPose], at frame: Float) -> [JointPose] {
        sk.joints.indices.map { pose(clip, sk.joints[$0].nameHash, at: frame) ?? rest[$0] }
    }

    /// One frame of a clip as joint poses.
    static func frame(_ clip: AnimClip, _ f: Int) -> [UInt32: JointPose] {
        clip.tracks.compactMapValues { $0.isEmpty ? nil : $0[min(max(f, 0), $0.count - 1)] }
    }

    /// "Spell2_-90" → -90, "Spell2" → 0; nil for clips that aren't the spell itself ("Spell2_to_Idle").
    static func direction(of label: String, spell: String) -> Float? {
        let l = label.lowercased(), s = spell.lowercased()
        if l == s { return 0 }
        guard l.hasPrefix(s + "_") else { return nil }
        return Float(l.dropFirst(s.count + 1))
    }
}
