import Foundation
import simd

/// A champion skeleton (.skl). Model vertices point at joints through `influences`.
struct Skeleton {
    struct Joint {
        let name: String
        let parent: Int          // -1 for the root
        let bind: simd_float4x4  // joint → model space, in the bind (rest) pose
        var local = SIMD3<Float>(0, 0, 0)   // position relative to the parent, as stored
        var nameHash: UInt32 = 0            // ELF hash of the name (how animations refer to joints)
        var record = -1                     // where this joint's 100 bytes start in the file
        var position: SIMD3<Float> { SIMD3(bind.columns.3.x, bind.columns.3.y, bind.columns.3.z) }
    }

    var joints: [Joint] = []
    /// Model bone index → joint index.
    var influences: [Int] = []

    static func parse(_ data: Data) throws -> Skeleton {
        var r = ByteReader(data)
        _ = try r.num(UInt32.self)                                  // file size
        guard try r.num(UInt32.self) == 0x22FD_4FC3 else { throw FormatError("Unsupported skeleton format (old .skl)") }
        _ = try r.num(UInt32.self)                                  // version
        _ = try r.num(UInt16.self)                                  // flags
        let jointCount = Int(try r.num(UInt16.self))
        let influenceCount = Int(try r.num(UInt32.self))
        let jointsOffset = Int(try r.num(Int32.self))
        _ = try r.num(Int32.self)                                   // joint index lookup
        let influencesOffset = Int(try r.num(Int32.self))

        var sk = Skeleton()
        for i in 0 ..< jointCount {
            r.pos = jointsOffset + i * 100
            _ = try r.num(UInt16.self)                              // flags
            _ = try r.num(Int16.self)                               // id
            let parent = Int(try r.num(Int16.self))
            try r.skip(2)
            let nameHash: UInt32 = try r.num()
            _ = try r.float()                                       // radius
            let local = SIMD3(try r.float(), try r.float(), try r.float())
            try r.skip(28)                                          // local scale + rotation
            let t = SIMD3(try r.float(), try r.float(), try r.float())
            let s = SIMD3(try r.float(), try r.float(), try r.float())
            let q = simd_quatf(ix: try r.float(), iy: try r.float(), iz: try r.float(), r: try r.float())
            let nameField = r.pos
            let nameOffset = Int(try r.num(Int32.self))
            var name = ""
            if nameField + nameOffset < data.count {
                let start = data.startIndex + nameField + nameOffset
                name = String(decoding: data[start...].prefix { $0 != 0 }, as: UTF8.self)
            }
            let inverseBind = trs(t, q, s)
            sk.joints.append(Joint(name: name, parent: parent, bind: inverseBind.inverse, local: local, nameHash: nameHash,
                                   record: jointsOffset + i * 100))
        }
        r.pos = influencesOffset
        for _ in 0 ..< influenceCount { sk.influences.append(Int(try r.num(Int16.self))) }
        return sk
    }

    static func trs(_ t: SIMD3<Float>, _ q: simd_quatf, _ s: SIMD3<Float>) -> simd_float4x4 {
        var m = simd_float4x4(q)
        m.columns.0 *= s.x
        m.columns.1 *= s.y
        m.columns.2 *= s.z
        m.columns.3 = SIMD4(t, 1)
        return m
    }

    func isAncestor(_ a: Int, of b: Int) -> Bool {
        var j = joints[b].parent
        while j >= 0 {
            if j == a { return true }
            j = joints[j].parent
        }
        return false
    }

    func index(named name: String) -> Int? { joints.firstIndex { $0.name.lowercased() == name.lowercased() } }

    /// ELF hash, lowercase: how .skl and .anm files name joints.
    static func elf(_ name: String) -> UInt32 {
        var h: UInt32 = 0
        for b in name.lowercased().utf8 {
            h = (h << 4) &+ UInt32(b)
            let high = h & 0xF000_0000
            if high != 0 { h ^= high >> 24 }
            h &= ~high
        }
        return h
    }
}

/// Shorter legs: some joints' positions (relative to their parent) scaled, and the body lowered to keep the feet down.
struct LegPlan {
    var bodyRoot: Int            // joint lowered by `drop` (the top of the body hierarchy)
    var drop: Float
    var scales: [Int: Float]     // joint index → factor on its position relative to its parent
    var rootBindHeight: Float    // the body root's height in the rest pose

    /// The same change for an animation key of a joint (by ELF hash).
    func animationChange(_ sk: Skeleton) -> (joints: Set<UInt32>, change: AnimEdit.Change) {
        var factor: [UInt32: Float] = [:]
        for (j, k) in scales { factor[sk.joints[j].nameHash] = k }
        let root = sk.joints[bodyRoot].nameHash
        let drop = drop, rest = max(rootBindHeight, 1)
        return (Set(factor.keys).union([root]), { joint, v in
            if joint == root {
                // Lower by the full amount when standing or higher, less when crouched, so feet stay on the floor.
                return v - SIMD3(0, drop * min(max(v.y / rest, 0), 1), 0)
            }
            return v * (factor[joint] ?? 1)
        })
    }
}

extension Skeleton {
    private func linear(_ m: simd_float4x4) -> simd_float3x3 {
        simd_float3x3(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z), SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
                      SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
    }

    /// How far each joint moves in the rest pose under a plan.
    func displacements(_ plan: LegPlan) -> [SIMD3<Float>] {
        var d = [SIMD3<Float>?](repeating: nil, count: joints.count)
        func get(_ j: Int) -> SIMD3<Float> {
            if let v = d[j] { return v }
            let p = joints[j].parent
            var v = p >= 0 && p < joints.count ? get(p) : SIMD3<Float>(0, 0, 0)
            if let k = plan.scales[j] {
                let parentLinear = p >= 0 ? linear(joints[p].bind) : matrix_identity_float3x3
                v += parentLinear * ((k - 1) * joints[j].local)
            }
            if j == plan.bodyRoot { v.y -= plan.drop }
            d[j] = v
            return v
        }
        return joints.indices.map(get)
    }

    func applying(_ plan: LegPlan) -> Skeleton {
        let d = displacements(plan)
        var out = self
        out.joints = joints.enumerated().map { j, joint in
            var bind = joint.bind
            bind.columns.3 += SIMD4(d[j], 0)
            var local = joint.local
            if let k = plan.scales[j] { local *= k }
            if j == plan.bodyRoot { local.y -= plan.drop }
            var nj = Joint(name: joint.name, parent: joint.parent, bind: bind, local: local, nameHash: joint.nameHash, record: joint.record)
            nj.local = local
            return nj
        }
        return out
    }

    /// An .skl with one more joint (e.g. a weapon bone in a hand): placed on its parent in the rest pose.
    /// Returns the file, the skeleton with the joint, and the joint's model bone slot (influence).
    func appendingJoint(_ file: Data, name: String, parent: Int) -> (data: Data, skeleton: Skeleton, influence: Int)? {
        let d = [UInt8](file)
        guard d.count > 64, parent >= 0, parent < joints.count else { return nil }
        func u16(_ o: Int) -> Int { Int(d[o]) | Int(d[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { Int(UInt32(d[o]) | UInt32(d[o + 1]) << 8 | UInt32(d[o + 2]) << 16 | UInt32(d[o + 3]) << 24) }
        let jointCount = u16(14), influenceCount = u32(16), jointsOffset = u32(20), influencesOffset = u32(28)
        let nameOffset = u32(32), boneNamesOffset = u32(40)
        guard jointCount == joints.count, jointsOffset + jointCount * 100 <= d.count, boneNamesOffset <= d.count else { return nil }
        let hash = Skeleton.elf(name)
        var records: [[UInt8]] = (0 ..< jointCount).map { Array(d[jointsOffset + $0 * 100 ..< jointsOffset + $0 * 100 + 100]) }
        // The new joint: like its parent's record (same rest place), identity local transform.
        var r = records[parent]
        func put16(_ a: inout [UInt8], _ o: Int, _ v: Int) { a[o] = UInt8(v & 0xFF); a[o + 1] = UInt8((v >> 8) & 0xFF) }
        func put32(_ a: inout [UInt8], _ o: Int, _ v: UInt32) { for i in 0 ..< 4 { a[o + i] = UInt8((v >> (8 * UInt32(i))) & 0xFF) } }
        func putF(_ a: inout [UInt8], _ o: Int, _ v: Float) { put32(&a, o, v.bitPattern) }
        put16(&r, 0, 0); put16(&r, 2, jointCount); put16(&r, 4, parent); put16(&r, 6, 0)
        put32(&r, 8, hash)
        for (k, v) in [Float(0), 0, 0, 1, 1, 1, 0, 0, 0, 1].enumerated() { putF(&r, 16 + k * 4, v) }    // local t, s, q
        records.append(r)
        let names = joints.map(\.name) + [name]
        // Layout: header, joints, joint index (by hash), influences, the original name/asset strings, joint names.
        var out = [UInt8](repeating: 0, count: 64)
        let newJoints = 64, newIndex = newJoints + records.count * 100
        let newInfluences = newIndex + records.count * 8
        let influences = (0 ..< influenceCount).map { u16(influencesOffset + $0 * 2) } + [jointCount]
        let newStrings = newInfluences + influences.count * 2
        let middle = Array(d[nameOffset ..< boneNamesOffset])                 // skeleton and asset names
        let newBoneNames = newStrings + middle.count
        var nameBytes: [UInt8] = []
        var nameAt: [Int] = []
        for n in names { nameAt.append(newBoneNames + nameBytes.count); nameBytes += Array(n.utf8) + [0] }
        for (i, _) in records.enumerated() {
            let field = newJoints + i * 100 + 96
            put32(&records[i], 96, UInt32(bitPattern: Int32(nameAt[i] - field)))
        }
        for rec in records { out += rec }
        let byHash = records.enumerated().map { (id: $0.offset, hash: UInt32($0.element[8]) | UInt32($0.element[9]) << 8 | UInt32($0.element[10]) << 16 | UInt32($0.element[11]) << 24) }
            .sorted { $0.hash < $1.hash }
        for e in byHash { var b = [UInt8](repeating: 0, count: 8); put16(&b, 0, e.id); put32(&b, 4, e.hash); out += b }
        for i in influences { out += [UInt8(i & 0xFF), UInt8((i >> 8) & 0xFF)] }
        out += middle
        out += nameBytes
        while out.count % 4 != 0 { out.append(0) }
        // Header: same version/flags, new counts and offsets.
        out.replaceSubrange(4 ..< 14, with: d[4 ..< 14])
        put16(&out, 14, records.count)
        put32(&out, 16, UInt32(influences.count))
        put32(&out, 20, UInt32(newJoints)); put32(&out, 24, UInt32(newIndex)); put32(&out, 28, UInt32(newInfluences))
        put32(&out, 32, UInt32(newStrings + (nameOffset - nameOffset))); put32(&out, 36, UInt32(newStrings + (u32(36) - nameOffset)))
        put32(&out, 40, UInt32(newBoneNames))
        for k in 0 ..< 5 { put32(&out, 44 + k * 4, 0xFFFF_FFFF) }
        put32(&out, 0, UInt32(out.count))
        var sk = self
        // record -1: its rest pose isn't in the original file (it sits on its parent, unturned).
        sk.joints.append(Joint(name: name, parent: parent, bind: joints[parent].bind, local: .zero, nameHash: hash, record: -1))
        sk.influences = influences
        // The new file's joints are at the same places as before (the header size didn't change).
        return (Data(out), sk, influences.count - 1)
    }

    /// The original .skl with the changed joints' positions rewritten.
    func patchedFile(_ original: Data, changedTo new: Skeleton) -> Data {
        var d = [UInt8](original)
        func putVec(_ o: Int, _ v: SIMD3<Float>) {
            for (k, f) in [v.x, v.y, v.z].enumerated() {
                let b = f.bitPattern
                for i in 0 ..< 4 { d[o + k * 4 + i] = UInt8((b >> (8 * UInt32(i))) & 0xFF) }
            }
        }
        for (j, joint) in new.joints.enumerated() where joint.record >= 0 && joint.record + 100 <= d.count {
            if joint.local != joints[j].local { putVec(joint.record + 16, joint.local) }
            if joint.bind.columns.3 != joints[j].bind.columns.3 {
                let inv = joint.bind.inverse.columns.3
                putVec(joint.record + 56, SIMD3(inv.x, inv.y, inv.z))
            }
        }
        return Data(d)
    }
}
