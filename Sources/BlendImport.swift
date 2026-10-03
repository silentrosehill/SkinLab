import Foundation
import ImageIO
import simd

/// A Blender file (.blend), read through the description of its own data structures it carries (its "SDNA"), so files
/// from Blender 2.8 to 4.x open without Blender installed. Compressed files (zstd, gzip) are unpacked first.
final class BlendFile {
    struct Block { let code: String; let offset: Int; let size: Int; let old: UInt64; let sdna: Int; let count: Int }
    struct Field { let type: String; let name: String; let offset: Int; let size: Int; let isPointer: Bool; let count: Int }
    struct StructDef { let name: String; let size: Int; let fields: [String: Field]; let order: [Field] }

    let bytes: [UInt8]
    private(set) var pointerSize = 8
    private(set) var blocks: [Block] = []
    private var byPointer: [UInt64: Int] = [:]
    private(set) var structs: [StructDef] = []
    private(set) var structIndex: [String: Int] = [:]

    init(_ url: URL) throws {
        var d = try Data(contentsOf: url, options: .alwaysMapped)
        if d.starts(with: [0x28, 0xB5, 0x2F, 0xFD]) || d.starts(with: [0x1F, 0x8B]) {
            let zstd = d.first == 0x28
            var size = 0
            let p = d.withUnsafeBytes { zstd ? sl_zstd_decompress_all($0.baseAddress, d.count, &size) : sl_gzip_decompress_all($0.baseAddress, d.count, &size) }
            guard let p else { throw FormatError("This Blender file is damaged") }
            d = Data(bytesNoCopy: p, count: size, deallocator: .free)
        }
        guard d.starts(with: Data("BLENDER".utf8)), d.count > 32 else { throw FormatError("Not a Blender file") }
        bytes = [UInt8](d)
        try readBlocks()
        guard let dna = blocks.first(where: { $0.code == "DNA1" }) else { throw FormatError("Unreadable Blender file") }
        try readSDNA(dna.offset)
    }

    // MARK: Raw reads (little-endian)

    func u16(_ o: Int) -> UInt16 { bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt16.self) } }
    func i16(_ o: Int) -> Int16 { Int16(bitPattern: u16(o)) }
    func u32(_ o: Int) -> UInt32 { bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) } }
    func i32(_ o: Int) -> Int32 { Int32(bitPattern: u32(o)) }
    func u64(_ o: Int) -> UInt64 { bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt64.self) } }
    func f32(_ o: Int) -> Float { Float(bitPattern: u32(o)) }
    func pointer(_ o: Int) -> UInt64 { pointerSize == 8 ? u64(o) : UInt64(u32(o)) }

    func floats(_ o: Int, _ n: Int) -> [Float] {
        guard n > 0, o >= 0, o + 4 * n <= bytes.count else { return [] }
        return bytes.withUnsafeBytes { raw in (0 ..< n).map { raw.loadUnaligned(fromByteOffset: o + 4 * $0, as: Float.self) } }
    }
    func ints(_ o: Int, _ n: Int) -> [Int32] {
        guard n > 0, o >= 0, o + 4 * n <= bytes.count else { return [] }
        return bytes.withUnsafeBytes { raw in (0 ..< n).map { raw.loadUnaligned(fromByteOffset: o + 4 * $0, as: Int32.self) } }
    }

    private func readBlocks() throws {
        let b = bytes
        var pos: Int
        let large: Bool
        if b[7] >= 0x30 && b[7] <= 0x39 {                     // Blender 5: "BLENDER17-01v0500", 64-bit block sizes
            pos = Int(String(decoding: b[7 ... 8], as: UTF8.self)) ?? 17
            pointerSize = b[9] == UInt8(ascii: "-") ? 8 : 4
            guard b[12] == UInt8(ascii: "v") else { throw FormatError("Big-endian Blender files aren't supported") }
            large = true
        } else {                                              // "BLENDER-v402"
            pointerSize = b[7] == UInt8(ascii: "-") ? 8 : 4
            guard b[8] == UInt8(ascii: "v") else { throw FormatError("Big-endian Blender files aren't supported") }
            pos = 12
            large = false
        }
        while pos + 16 + pointerSize <= b.count {
            let code = String(decoding: b[pos ..< pos + 4].prefix { $0 != 0 }, as: UTF8.self)
            let size, sdna, count, header: Int
            let old: UInt64
            if large {
                sdna = Int(i32(pos + 4)); old = u64(pos + 8); size = Int(Int64(bitPattern: u64(pos + 16))); count = Int(Int64(bitPattern: u64(pos + 24)))
                header = 32
            } else {
                size = Int(i32(pos + 4)); old = pointer(pos + 8)
                sdna = Int(i32(pos + 8 + pointerSize)); count = Int(i32(pos + 12 + pointerSize))
                header = 16 + pointerSize
            }
            if code == "ENDB" { break }
            guard size >= 0, pos + header + size <= b.count else { throw FormatError("This Blender file is cut short") }
            if old != 0 { byPointer[old] = blocks.count }
            blocks.append(Block(code: code, offset: pos + header, size: size, old: old, sdna: sdna, count: count))
            pos += header + size
        }
    }

    private func readSDNA(_ start: Int) throws {
        var p = start
        func align() { p = start + ((p - start + 3) & ~3) }
        func tag(_ t: String) throws {
            guard p + 4 <= bytes.count, String(decoding: bytes[p ..< p + 4], as: UTF8.self) == t else { throw FormatError("Unreadable Blender file") }
            p += 4
        }
        func cstring() -> String {
            var e = p
            while e < bytes.count && bytes[e] != 0 { e += 1 }
            let s = String(decoding: bytes[p ..< e], as: UTF8.self)
            p = e + 1
            return s
        }
        try tag("SDNA"); try tag("NAME")
        let nameCount = Int(i32(p))
        p += 4
        let fieldNames = (0 ..< nameCount).map { _ in cstring() }
        align(); try tag("TYPE")
        let typeCount = Int(i32(p)); p += 4
        let types = (0 ..< typeCount).map { _ in cstring() }
        align(); try tag("TLEN")
        let tlen = (0 ..< typeCount).map { Int(i16(p + 2 * $0)) }
        p += 2 * typeCount
        align(); try tag("STRC")
        let structCount = Int(i32(p)); p += 4
        for _ in 0 ..< structCount {
            let t = Int(i16(p)), n = Int(i16(p + 2))
            p += 4
            var fields: [String: Field] = [:], order: [Field] = []
            var offset = 0
            for _ in 0 ..< n {
                let ft = Int(i16(p)), fn = Int(i16(p + 2))
                p += 4
                let raw = fieldNames[fn]
                let isPointer = raw.hasPrefix("*") || raw.hasPrefix("(*")
                var count = 1
                var rest = Substring(raw)
                while let open = rest.firstIndex(of: "["), let close = rest[open...].firstIndex(of: "]") {
                    count *= Int(rest[rest.index(after: open) ..< close]) ?? 1
                    rest = rest[rest.index(after: close)...]
                }
                let base = String(raw.drop { $0 == "*" || $0 == "(" }.prefix { $0 != "[" && $0 != ")" })
                let size = (isPointer ? pointerSize : tlen[ft]) * count
                let f = Field(type: types[ft], name: base, offset: offset, size: size, isPointer: isPointer, count: count)
                if fields[base] == nil { fields[base] = f }
                order.append(f)
                offset += size
            }
            structIndex[types[t]] = structs.count
            structs.append(StructDef(name: types[t], size: tlen[t], fields: fields, order: order))
        }
    }

    // MARK: Structures

    /// A structure in the file: its type and where it is.
    struct View {
        let file: BlendFile
        let def: Int
        let offset: Int
        var pointer: UInt64 = 0         // its address in the file's pointers, when it starts a block

        var type: String { file.structs[def].name }
        func field(_ n: String) -> Field? { file.structs[def].fields[n] }
        func has(_ n: String) -> Bool { field(n) != nil }

        func ptr(_ n: String) -> UInt64 {
            guard let f = field(n), f.isPointer else { return 0 }
            return file.pointer(offset + f.offset)
        }
        func follow(_ n: String) -> View? { file.view(at: ptr(n)) }

        func int(_ n: String, _ i: Int = 0) -> Int {
            guard let f = field(n), !f.isPointer else { return 0 }
            let elem = f.size / max(f.count, 1), o = offset + f.offset + i * elem
            switch elem {
            case 1: return f.type == "char" || f.type == "int8_t" ? Int(Int8(bitPattern: file.bytes[o])) : Int(file.bytes[o])
            case 2: return f.type.hasPrefix("u") ? Int(file.u16(o)) : Int(file.i16(o))
            case 4: return f.type == "float" ? Int(file.f32(o)) : f.type.hasPrefix("u") ? Int(file.u32(o)) : Int(file.i32(o))
            case 8: return Int(truncatingIfNeeded: file.u64(o))
            default: return 0
            }
        }
        func float(_ n: String, _ i: Int = 0) -> Float {
            guard let f = field(n), !f.isPointer else { return 0 }
            if f.type == "double" { return Float(Double(bitPattern: file.u64(offset + f.offset + 8 * i))) }
            return f.type == "float" ? file.f32(offset + f.offset + 4 * i) : Float(int(n, i))
        }
        func floats(_ n: String) -> [Float] {
            guard let f = field(n), f.type == "float" else { return [] }
            return file.floats(offset + f.offset, f.count)
        }
        func string(_ n: String) -> String {
            guard let f = field(n), !f.isPointer else { return "" }
            let s = file.bytes[offset + f.offset ..< offset + f.offset + f.size]
            return String(decoding: s.prefix { $0 != 0 }, as: UTF8.self)
        }
        func sub(_ n: String) -> View? {
            guard let f = field(n), !f.isPointer, let i = file.structIndex[f.type] else { return nil }
            return View(file: file, def: i, offset: offset + f.offset)
        }
        /// A data-block's name ("OBTop" → "Top").
        var idName: String { String(sub("id")?.string("name").dropFirst(2) ?? "") }
    }

    func block(at pointer: UInt64) -> Block? { pointer == 0 ? nil : byPointer[pointer].map { blocks[$0] } }

    func view(at pointer: UInt64) -> View? {
        guard let b = block(at: pointer), b.sdna >= 0, b.sdna < structs.count else { return nil }
        return View(file: self, def: b.sdna, offset: b.offset, pointer: pointer)
    }

    func views(_ code: String) -> [View] {
        blocks.filter { $0.code == code && $0.sdna < structs.count }.map { View(file: self, def: $0.sdna, offset: $0.offset, pointer: $0.old) }
    }

    /// The items of a linked list (ListBase).
    func list(_ lb: View?) -> [View] {
        var out: [View] = []
        var p = lb?.ptr("first") ?? 0
        var seen = Set<UInt64>()
        while p != 0, seen.insert(p).inserted, let v = view(at: p) {
            out.append(v)
            if v.has("next") { p = v.ptr("next") }
            else if let first = structs[v.def].order.first, let head = v.sub(first.name) { p = head.ptr("next") }      // modifiers…
            else { p = 0 }
        }
        return out
    }

    /// An array of pointers (e.g. a mesh's material slots).
    func pointers(at pointer: UInt64, count: Int) -> [UInt64] {
        guard let b = block(at: pointer) else { return [] }
        return (0 ..< min(count, b.size / pointerSize)).map { self.pointer(b.offset + $0 * pointerSize) }
    }

    /// A mesh's attribute layers (positions, UV maps, weights…).
    func layers(_ cd: View?) -> [View] {
        guard let cd, let b = block(at: cd.ptr("layers")), let def = structIndex["CustomDataLayer"] else { return [] }
        let size = structs[def].size
        return (0 ..< min(cd.int("totlayer"), b.size / max(size, 1))).map { View(file: self, def: def, offset: b.offset + $0 * size) }
    }
}

/// Characters made in Blender (.blend): the meshes the file shows (hidden outfits and variants stay out), with their
/// armature's weights and the color texture of each material, made into a skin-like model the porter can use.
enum BlendImport {
    /// Blender meters → League units (a 1.6 m character is ~200 tall), Blender's Z-up / -Y-forward → League's Y-up / +Z-forward.
    static func league(_ p: SIMD3<Float>) -> SIMD3<Float> { SIMD3(-p.x, p.z, -p.y) * 125 }

    struct Bone { var name: String; var parent: Int; var head: SIMD3<Float>; var tail: SIMD3<Float> }

    static func load(_ url: URL) throws -> SkinData {
        let f = try BlendFile(url)
        let objects = f.views("OB")
        guard !objects.isEmpty else { throw FormatError("This Blender file has no objects") }

        // The meshes shown when the file opens.
        func flags(_ o: BlendFile.View) -> Int { o.int("base_flag") }
        let meshObjects = objects.filter { $0.int("type") == 1 && $0.int("restrictflag") & 1 == 0 }
        var shown = meshObjects.filter { flags($0) & 64 != 0 && flags($0) & 256 == 0 }
        if shown.isEmpty { shown = meshObjects.filter { flags($0) & 2 != 0 } }
        if shown.isEmpty { shown = meshObjects }

        func armature(of o: BlendFile.View) -> BlendFile.View? {
            for m in f.list(o.sub("modifiers")) where m.type == "ArmatureModifierData" {
                if let md = m.sub("modifier"), md.int("mode") & 1 == 0 { continue }
                if let a = m.follow("object"), a.type == "Object", a.int("type") == 25 { return a }
            }
            if let p = o.follow("parent"), p.type == "Object", p.int("type") == 25, o.int("partype") == 4 { return p }
            return nil
        }
        // The armature most of the model uses.
        var votes: [UInt64: Int] = [:]
        for o in shown { if let a = armature(of: o), let me = o.follow("data") { votes[a.pointer, default: 0] += max(me.int("totvert"), me.int("verts_num")) } }
        guard let rigPointer = votes.max(by: { $0.value < $1.value })?.key, let rig = f.view(at: rigPointer),
              let arm = rig.follow("data") else { throw FormatError("This Blender model has no armature (bones)") }
        let rigWorld = world(rig, f)

        // Bones (all of them; only those moving the model are kept later).
        var bones: [Bone] = []
        func walk(_ lb: BlendFile.View?, _ parent: Int) {
            for b in f.list(lb) {
                let h = b.floats("arm_head"), t = b.floats("arm_tail")
                guard h.count == 3, t.count == 3 else { continue }
                let head = rigWorld * SIMD4(h[0], h[1], h[2], 1), tail = rigWorld * SIMD4(t[0], t[1], t[2], 1)
                bones.append(Bone(name: b.string("name"), parent: parent, head: SIMD3(head.x, head.y, head.z), tail: SIMD3(tail.x, tail.y, tail.z)))
                walk(b.sub("childbase"), bones.count - 1)
            }
        }
        walk(arm.sub("bonebase"), -1)
        guard !bones.isEmpty else { throw FormatError("This Blender model's armature has no bones") }
        var boneIndex: [String: Int] = [:]
        for (i, b) in bones.enumerated() where boneIndex[b.name] == nil { boneIndex[b.name] = i }

        // Meshes → one model: vertices split where UVs differ, faces grouped by texture.
        var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], uvs: [SIMD2<Float>] = []
        var vertexBones: [[(Int, Float)]] = []
        var groups: [String: (name: String, faces: Int, triangles: [SIMD3<Int32>])] = [:]       // by texture key
        var groupOrder: [String] = []
        var images: [String: RGBAImage?] = [:]
        var textureOf: [UInt64: (key: String, image: RGBAImage?)] = [:]
        let folder = url.deletingLastPathComponent()

        for o in shown {
            let usesRig = armature(of: o)?.pointer == rigPointer
            let boneParent = o.int("partype") == 7 && o.follow("parent")?.pointer == rigPointer ? boneIndex[o.string("parsubstr")] : nil
            guard usesRig || boneParent != nil, let me = o.follow("data"), me.type == "Mesh", let mesh = readMesh(me, o, f) else { continue }
            let m = world(o, f)
            let world = mesh.positions.map { p -> SIMD3<Float> in let w = m * SIMD4(p, 1); return SIMD3(w.x, w.y, w.z) }

            // Masks (hide the body under clothes…).
            var keep = [Bool](repeating: true, count: world.count)
            for md in f.list(o.sub("modifiers")) where md.type == "MaskModifierData" && (md.sub("modifier")?.int("mode") ?? 1) & 1 != 0 && md.int("mode") == 0 {
                guard let g = mesh.groupNames.firstIndex(of: md.string("vgroup")) else { continue }
                let threshold = md.float("threshold"), invert = md.int("flag") & 1 != 0
                for v in keep.indices {
                    let w = mesh.weights[v].first { $0.0 == g }?.1 ?? 0
                    if (w > threshold) == invert { keep[v] = false }
                }
            }

            // Smooth normals.
            var vn = [SIMD3<Float>](repeating: .zero, count: world.count)
            for face in mesh.faces where face.count >= 3 {
                for k in 1 ..< face.count - 1 {
                    let a = Int(face[0].vertex), b = Int(face[k].vertex), c = Int(face[k + 1].vertex)
                    let n = simd_cross(world[b] - world[a], world[c] - world[a])
                    vn[a] += n; vn[b] += n; vn[c] += n
                }
            }

            // Weights: bones of the armature by vertex-group name.
            let groupBone = mesh.groupNames.map { boneIndex[$0] }
            var outIndex: [SIMD3<UInt32>: Int32] = [:]
            func vertex(_ v: Int, _ uv: SIMD2<Float>) -> Int32 {
                let key = SIMD3(UInt32(v), uv.x.bitPattern, uv.y.bitPattern)
                if let i = outIndex[key] { return i }
                let i = Int32(positions.count)
                outIndex[key] = i
                positions.append(league(world[v]))
                let n = simd_length(vn[v]) > 0 ? simd_normalize(vn[v]) : SIMD3<Float>(0, 0, 1)
                normals.append(SIMD3(-n.x, n.z, -n.y))
                uvs.append(uv)
                if let bp = boneParent {
                    vertexBones.append([(bp, 1)])
                } else {
                    var bw: [(Int, Float)] = []
                    for (g, w) in mesh.weights[v] where w > 0 && g < groupBone.count { if let b = groupBone[g] { bw.append((b, w)) } }
                    vertexBones.append(bw)
                }
                return i
            }

            // Faces by material texture.
            for face in mesh.faces where face.count >= 3 && face.allSatisfy({ keep[Int($0.vertex)] }) {
                let slot = min(max(face.first!.material, 0), max(mesh.materials.count - 1, 0))
                let mat = mesh.materials.indices.contains(slot) ? mesh.materials[slot] : nil
                let matPointer = mat?.pointer ?? 0
                if textureOf[matPointer] == nil {
                    // Toon outlines (an inflated inside-out copy of the model) only draw an outline in Blender.
                    let mname = mat?.idName.lowercased() ?? ""
                    if mname.contains("outline") || mname.hasPrefix("line") { textureOf[matPointer] = ("skip", nil); continue }
                    let tex = mat.flatMap { colorTexture($0, f, folder: folder, cache: &images) }
                    textureOf[matPointer] = (tex?.key ?? "m\(matPointer)", tex?.image)
                }
                guard let tex = textureOf[matPointer], tex.key != "skip" else { continue }
                if groups[tex.key] == nil { groups[tex.key] = (partName(mat?.idName ?? "Model"), 0, []); groupOrder.append(tex.key) }
                let ids = face.map { vertex(Int($0.vertex), $0.uv) }
                for k in 1 ..< ids.count - 1 { groups[tex.key]!.triangles.append(SIMD3(ids[0], ids[k], ids[k + 1])) }
                groups[tex.key]!.faces += 1
                guard positions.count < 2_000_000 else { throw FormatError("This Blender model is too big") }
            }
        }
        guard !positions.isEmpty else { throw FormatError("This Blender file shows no model rigged to bones") }

        var textureImages: [String: RGBAImage] = [:]
        for (_, t) in textureOf { if let img = t.image { textureImages[t.key] = img } }
        let parts = groupOrder.compactMap { key -> ModelImport.Part? in
            guard let g = groups[key], !g.triangles.isEmpty else { return nil }
            return ModelImport.Part(name: g.name, triangles: g.triangles, texture: textureImages[key] != nil ? key : nil)
        }
        var mesh = SkinnedMesh()
        mesh.positions = positions; mesh.normals = normals; mesh.uvs = uvs
        return try finish(mesh, bones: bones, vertexBones: vertexBones, parts: parts, textures: textureImages, source: url)
    }

    /// The model made from its vertices (League space), the armature's bones (Blender space: meters, Z up, facing -Y) and
    /// each vertex's weights on them: bones that move the model kept in a clean hierarchy and named for the porter.
    static func finish(_ mesh: SkinnedMesh, bones: [Bone], vertexBones: [[(Int, Float)]], parts: [ModelImport.Part],
                       textures: [String: RGBAImage], source url: URL) throws -> SkinData {
        var vertexBones = vertexBones
        var weightOf = [Float](repeating: 0, count: bones.count)
        for vb in vertexBones { for (b, w) in vb where b < bones.count { weightOf[b] += w } }
        var rigged = cleanRig(bones, weightOf)
        vertexBones = vertexBones.map { vb in
            var merged: [Int: Float] = [:]
            for (b, w) in vb { if let to = rigged.map[b] { merged[to, default: 0] += w } }
            return merged.map { ($0.key, $0.value) }
        }
        var finalWeight = [Float](repeating: 0, count: rigged.bones.count)
        for vb in vertexBones { for (b, w) in vb { finalWeight[b] += w } }
        inferBody(&rigged.bones, finalWeight)
        // Vertices with no weights follow the nearest bone.
        for v in vertexBones.indices where vertexBones[v].isEmpty {
            let p = mesh.positions[v]
            if let near = rigged.bones.indices.min(by: { segmentDistance(p, rigged.bones[$0]) < segmentDistance(p, rigged.bones[$1]) }) {
                vertexBones[v] = [(near, 1)]
            }
        }
        let (sk, bi, bw) = ModelImport.rig(names: rigged.bones.map(\.name), parents: rigged.bones.map(\.parent),
                                           positions: rigged.bones.map { league($0.head) }, vertexBones: vertexBones)
        var mesh = mesh
        mesh.boneIndices = bi; mesh.weights = bw
        let name = url.deletingPathExtension().lastPathComponent
        return try ModelImport.assemble(mesh, parts: parts, skeleton: sk, name: name, source: url) { textures[$0] }
    }

    // MARK: Meshes

    struct Corner { var vertex: Int32; var uv: SIMD2<Float>; var material: Int }
    struct MeshData {
        var positions: [SIMD3<Float>]
        var faces: [[Corner]]
        var weights: [[(Int, Float)]]          // per vertex: (vertex group, weight)
        var groupNames: [String]
        var materials: [BlendFile.View?]       // per slot (nil: none)
    }

    /// Positions, faces (with UVs and material slots), vertex-group weights and materials of a mesh, from the attribute
    /// layers of Blender 3.5+ or the older vertex / face / loop arrays.
    static func readMesh(_ me: BlendFile.View, _ ob: BlendFile.View, _ f: BlendFile) -> MeshData? {
        func count(_ names: String...) -> Int { names.lazy.map { me.int($0) }.first { $0 > 0 } ?? 0 }
        let nv = count("totvert", "verts_num"), np = count("totpoly", "faces_num"), nl = count("totloop", "corners_num")
        guard nv > 0, np > 0, nl > 0 else { return nil }
        let vdata = f.layers(me.sub("vdata")), pdata = f.layers(me.sub("pdata")), ldata = f.layers(me.sub("ldata"))
        func data(_ l: BlendFile.View) -> BlendFile.Block? { f.block(at: l.ptr("data")) }

        // Positions
        var positions: [SIMD3<Float>] = []
        if let l = vdata.first(where: { $0.int("type") == 48 && $0.string("name") == "position" }), let b = data(l) {
            let raw = f.floats(b.offset, 3 * nv)
            positions = stride(from: 0, to: raw.count - 2, by: 3).map { SIMD3(raw[$0], raw[$0 + 1], raw[$0 + 2]) }
        } else if let l = vdata.first(where: { $0.int("type") == 0 }), let b = data(l), let def = f.structIndex["MVert"] {
            let size = f.structs[def].size
            positions = (0 ..< nv).map { BlendFile.View(file: f, def: def, offset: b.offset + $0 * size).floats("co") }
                .map { $0.count == 3 ? SIMD3($0[0], $0[1], $0[2]) : .zero }
        }
        guard positions.count == nv else { return nil }

        // Faces: first corner of each, and the vertex of each corner.
        var starts: [Int] = [], cornerVerts: [Int32] = [], faceMaterial = [Int](repeating: 0, count: np)
        if let b = f.block(at: me.ptr("poly_offset_indices")) ?? f.block(at: me.ptr("face_offset_indices")) {
            starts = f.ints(b.offset, np + 1).map(Int.init)
        }
        if let l = ldata.first(where: { $0.string("name") == ".corner_vert" }), let b = data(l) { cornerVerts = f.ints(b.offset, nl) }
        if let l = pdata.first(where: { $0.string("name") == "material_index" }), let b = data(l), case let m = f.ints(b.offset, np), m.count == np {
            faceMaterial = m.map(Int.init)
        }
        if starts.isEmpty, let l = pdata.first(where: { $0.int("type") == 25 }), let b = data(l), let def = f.structIndex["MPoly"] {
            let size = f.structs[def].size
            for i in 0 ..< np {
                let p = BlendFile.View(file: f, def: def, offset: b.offset + i * size)
                starts.append(p.int("loopstart"))
                faceMaterial[i] = p.int("mat_nr")
            }
            starts.append(nl)
        }
        if cornerVerts.isEmpty, let l = ldata.first(where: { $0.int("type") == 26 }), let b = data(l), let def = f.structIndex["MLoop"] {
            let size = f.structs[def].size
            cornerVerts = (0 ..< nl).map { Int32(BlendFile.View(file: f, def: def, offset: b.offset + $0 * size).int("v")) }
        }
        guard starts.count == np + 1, cornerVerts.count == nl else { return nil }

        // The UV map used for rendering.
        var cornerUV = [SIMD2<Float>](repeating: .zero, count: nl)
        let uvLayers = ldata.filter { $0.int("type") == 49 && !$0.string("name").hasPrefix(".") }
        let legacyUV = ldata.filter { $0.int("type") == 16 }
        if let first = uvLayers.first {
            let l = uvLayers[min(max(first.int("active_rnd"), 0), uvLayers.count - 1)]
            if let b = data(l) {
                let raw = f.floats(b.offset, 2 * nl)
                if raw.count == 2 * nl { cornerUV = (0 ..< nl).map { SIMD2(raw[2 * $0], 1 - raw[2 * $0 + 1]) } }
            }
        } else if let first = legacyUV.first, let def = f.structIndex["MLoopUV"] {
            let l = legacyUV[min(max(first.int("active_rnd"), 0), legacyUV.count - 1)]
            if let b = data(l) {
                let size = f.structs[def].size
                cornerUV = (0 ..< nl).map { i in
                    let uv = BlendFile.View(file: f, def: def, offset: b.offset + i * size).floats("uv")
                    return uv.count == 2 ? SIMD2(uv[0], 1 - uv[1]) : .zero
                }
            }
        }

        var faces: [[Corner]] = []
        faces.reserveCapacity(np)
        for i in 0 ..< np {
            let s = starts[i], e = starts[i + 1]
            guard s >= 0, e <= nl, e - s >= 3 else { continue }
            faces.append((s ..< e).compactMap { c in
                cornerVerts[c] >= 0 && Int(cornerVerts[c]) < nv ? Corner(vertex: cornerVerts[c], uv: cornerUV[c], material: faceMaterial[i]) : nil
            })
        }

        // Vertex groups
        var weights = [[(Int, Float)]](repeating: [], count: nv)
        if let l = vdata.first(where: { $0.int("type") == 2 }), let b = data(l), let def = f.structIndex["MDeformVert"] {
            let size = f.structs[def].size
            for v in 0 ..< min(nv, b.size / max(size, 1)) {
                let dv = BlendFile.View(file: f, def: def, offset: b.offset + v * size)
                let n = dv.int("totweight")
                guard n > 0, let wb = f.block(at: dv.ptr("dw")) else { continue }
                for k in 0 ..< min(n, wb.size / 8) {
                    let g = Int(f.i32(wb.offset + 8 * k)), w = f.f32(wb.offset + 8 * k + 4)
                    if g >= 0 && w > 0 { weights[v].append((g, w)) }
                }
            }
        }
        var groupNames = f.list(me.sub("vertex_group_names")).map { $0.string("name") }
        if groupNames.isEmpty { groupNames = f.list(ob.sub("defbase")).map { $0.string("name") } }

        // Shape keys as set in the file (a body reshaped to fit the outfit…): basis + value × (key − its reference).
        if let key = me.follow("key"), key.type == "Key", key.int("type") == 1 {
            let blocks = f.list(key.sub("block"))
            let data = blocks.map { kb -> [Float] in f.block(at: kb.ptr("data")).map { f.floats($0.offset, 3 * nv) } ?? [] }
            let lockedTo = ob.int("shapeflag") & 1 != 0 ? ob.int("shapenr") - 1 : nil       // "show only this shape key"
            for (i, kb) in blocks.enumerated().dropFirst() {
                let value: Float = lockedTo.map { $0 == i ? 1 : 0 } ?? kb.float("curval")
                let rel = min(max(kb.int("relative"), 0), blocks.count - 1)
                guard value != 0, lockedTo != nil || kb.int("flag") & 1 == 0, data[i].count == 3 * nv, data[rel].count == 3 * nv else { continue }
                let group = groupNames.firstIndex(of: kb.string("vgroup"))
                for v in 0 ..< nv {
                    var k = value
                    if let group { k *= weights[v].first { $0.0 == group }?.1 ?? 0 }
                    guard k != 0 else { continue }
                    positions[v] += k * SIMD3(data[i][3 * v] - data[rel][3 * v], data[i][3 * v + 1] - data[rel][3 * v + 1], data[i][3 * v + 2] - data[rel][3 * v + 2])
                }
            }
        }

        // Material slots (the object's own material where it overrides the mesh's).
        let slots = max(me.int("totcol"), 0)
        let meshMats = f.pointers(at: me.ptr("mat"), count: slots), obMats = f.pointers(at: ob.ptr("mat"), count: slots)
        let bits = f.block(at: ob.ptr("matbits"))
        var materials: [BlendFile.View?] = []
        for i in 0 ..< slots {
            let useObject = bits.map { i < $0.size && f.bytes[$0.offset + i] != 0 } ?? false
            let p = useObject && i < obMats.count ? obMats[i] : i < meshMats.count ? meshMats[i] : 0
            materials.append(f.view(at: p).flatMap { $0.type == "Material" ? $0 : nil })
        }
        if materials.isEmpty { materials = [nil] }
        return MeshData(positions: positions, faces: faces, weights: weights, groupNames: groupNames, materials: materials)
    }

    /// An object's placement in the scene (rest pose).
    static func world(_ o: BlendFile.View, _ f: BlendFile, depth: Int = 0) -> simd_float4x4 {
        func v3(_ n: String, _ fallback: SIMD3<Float>) -> SIMD3<Float> { let a = o.floats(n); return a.count == 3 ? SIMD3(a[0], a[1], a[2]) : fallback }
        let loc = v3("loc", .zero) + v3("dloc", .zero)
        var scale = v3("size", .one)
        let ds = v3("dscale", .one)
        if ds != .zero { scale *= ds }
        let mode = o.int("rotmode")
        func euler(_ e: SIMD3<Float>) -> simd_float3x3 {
            let rx = simd_float3x3(simd_quatf(angle: e.x, axis: SIMD3(1, 0, 0))), ry = simd_float3x3(simd_quatf(angle: e.y, axis: SIMD3(0, 1, 0)))
            let rz = simd_float3x3(simd_quatf(angle: e.z, axis: SIMD3(0, 0, 1)))
            switch mode {
            case 2: return ry * rz * rx          // XZY
            case 3: return rz * rx * ry          // YXZ
            case 4: return rx * rz * ry          // YZX
            case 5: return ry * rx * rz          // ZXY
            case 6: return rx * ry * rz          // ZYX
            default: return rz * ry * rx         // XYZ
            }
        }
        var r: simd_float3x3
        if mode == 0 {
            let q = o.floats("quat")
            r = q.count == 4 && simd_length(SIMD4(q[0], q[1], q[2], q[3])) > 0 ? simd_float3x3(simd_normalize(simd_quatf(ix: q[1], iy: q[2], iz: q[3], r: q[0]))) : matrix_identity_float3x3
        } else if mode == -1 {
            let axis = v3("rotAxis", SIMD3(0, 1, 0))
            r = simd_length(axis) > 0 ? simd_float3x3(simd_quatf(angle: o.float("rotAngle"), axis: simd_normalize(axis))) : matrix_identity_float3x3
        } else {
            r = euler(v3("drot", .zero)) * euler(v3("rot", .zero))
        }
        r = r * simd_float3x3(diagonal: scale)
        var local = simd_float4x4(SIMD4(r.columns.0, 0), SIMD4(r.columns.1, 0), SIMD4(r.columns.2, 0), SIMD4(loc, 1))
        guard depth < 32, let parent = o.follow("parent"), parent.type == "Object" else { return local }
        let pi = o.floats("parentinv")
        let inv = pi.count == 16 ? simd_float4x4(SIMD4(pi[0], pi[1], pi[2], pi[3]), SIMD4(pi[4], pi[5], pi[6], pi[7]),
                                                 SIMD4(pi[8], pi[9], pi[10], pi[11]), SIMD4(pi[12], pi[13], pi[14], pi[15])) : matrix_identity_float4x4
        var parentMatrix = world(parent, f, depth: depth + 1)
        if o.int("partype") == 7, let arm = parent.follow("data") {         // parented to a bone: its tail
            let name = o.string("parsubstr")
            func find(_ lb: BlendFile.View?) -> BlendFile.View? {
                for b in f.list(lb) { if b.string("name") == name { return b }; if let c = find(b.sub("childbase")) { return c } }
                return nil
            }
            if let b = find(arm.sub("bonebase")), case let m = b.floats("arm_mat"), m.count == 16 {
                var bm = simd_float4x4(SIMD4(m[0], m[1], m[2], m[3]), SIMD4(m[4], m[5], m[6], m[7]), SIMD4(m[8], m[9], m[10], m[11]), SIMD4(m[12], m[13], m[14], m[15]))
                bm.columns.3 += bm.columns.1 * b.float("length")
                parentMatrix = parentMatrix * bm
            }
        }
        local = parentMatrix * inv * local
        return local
    }

    // MARK: Textures

    /// The image a material is colored with: followed back from the material's output through its color inputs
    /// (normal maps, light maps, masks… skipped), and one the file holds or that's found next to it.
    static func colorTexture(_ mat: BlendFile.View, _ f: BlendFile, folder: URL, cache: inout [String: RGBAImage?]) -> (key: String, image: RGBAImage)? {
        guard let tree = mat.follow("nodetree") else { return nil }
        let nodes = f.list(tree.sub("nodes")), links = f.list(tree.sub("links"))
        var byPointer: [UInt64: BlendFile.View] = [:]
        for n in nodes { byPointer[n.pointer] = n }
        var into: [UInt64: [(socket: String, from: UInt64)]] = [:]
        var alphaUsed = Set<UInt64>()           // image nodes whose alpha drives something (transparency…)
        for l in links {
            let to = l.ptr("tonode"), from = l.ptr("fromnode")
            guard byPointer[to] != nil, byPointer[from] != nil else { continue }
            into[to, default: []].append((f.view(at: l.ptr("tosock"))?.string("name") ?? "", from))
            if f.view(at: l.ptr("fromsock"))?.string("name") == "Alpha" { alphaUsed.insert(from) }
        }
        // Follow color inputs only (not a mix's factor, a bump's height…), the likeliest first.
        let notColorInput = ["fac", "height", "normal", "strength", "alpha", "mask", "rough", "metal", "spec", "displace", "weight",
                             "distance", "ior", "scale", "vector", "radius", "anisotrop", "coat", "sheen", "transmission", "subsurface"]
        func rank(_ socket: String) -> Int {
            let s = socket.lowercased()
            return ["base color", "diffuse", "albedo", "main", "color", "col", "tex", "image"].firstIndex { s.contains($0) } ?? 10
        }
        var order: [(node: UInt64, image: BlendFile.View)] = [], seen = Set<UInt64>()
        var queue = nodes.filter { $0.string("idname") == "ShaderNodeOutputMaterial" }.map(\.pointer)
        while !queue.isEmpty {
            let p = queue.removeFirst()
            guard seen.insert(p).inserted, let n = byPointer[p] else { continue }
            if n.string("idname") == "ShaderNodeTexImage", let img = n.follow("id"), img.type == "Image" { order.append((p, img)) }
            queue += (into[p] ?? []).filter { s in
                !s.socket.lowercased().split(separator: " ").contains { w in notColorInput.contains { w.hasPrefix($0) } }
            }
                .sorted { rank($0.socket) < rank($1.socket) }.map(\.from)
        }
        // An image whose alpha blends it over another (a decal, a neck patch…) comes after the one under it.
        order = order.filter { !alphaUsed.contains($0.node) } + order.filter { alphaUsed.contains($0.node) }
        for n in nodes where n.string("idname") == "ShaderNodeTexImage" {
            if let img = n.follow("id"), img.type == "Image", !order.contains(where: { $0.node == n.pointer }) { order.append((n.pointer, img)) }
        }
        // Alpha is transparency only for a see-through material (clip / hashed / blend) that uses it.
        let seeThrough = mat.int("blend_method") != 0
        let notColor = ["normal", "nrm", "lightmap", "matcap", "mask", "shadow", "ramp", "specular", "metal", "rough", "displace", "sdf", "lut",
                        "emiss", "facet", "universe", "symbol", "blendshape", "_ao", "bump", "height", "outline", "_ilm", "gloss", "sphere"]
        func label(_ img: BlendFile.View) -> String { (img.idName + " " + URL(fileURLWithPath: path(img)).lastPathComponent).lowercased() }
        func key(_ e: (node: UInt64, image: BlendFile.View)) -> String {
            "\(e.image.pointer)" + (seeThrough && alphaUsed.contains(e.node) ? "a" : "")
        }
        func loads(_ e: (node: UInt64, image: BlendFile.View)) -> Bool {
            let k = key(e)
            if cache[k] == nil { cache[k] = .some(load(e.image, f, folder: folder, opaque: !k.hasSuffix("a"))) }
            return cache[k]! != nil
        }
        guard let pick = order.first(where: { e in !notColor.contains { label(e.image).contains($0) } && loads(e) })
                ?? order.first(where: { label($0.image).contains("diffuse") && loads($0) }),
              let image = cache[key(pick)] ?? nil else { return nil }
        if ProcessInfo.processInfo.environment["SKINLAB_BLENDDEBUG"] != nil {
            print("material \(mat.idName): \(pick.image.idName)\(key(pick).hasSuffix("a") ? " (with transparency)" : "") of \(order.map(\.image.idName))")
        }
        return (key(pick), image)
    }

    static func path(_ img: BlendFile.View) -> String {
        (img.has("filepath") ? img.string("filepath") : img.string("name")).replacingOccurrences(of: "\\", with: "/")
    }

    /// An image packed in the file, or its file (path relative to the .blend, or found by name in the .blend's folder).
    static func load(_ img: BlendFile.View, _ f: BlendFile, folder: URL, opaque: Bool) -> RGBAImage? {
        var packed = img.follow("packedfile")
        if packed == nil { packed = f.list(img.sub("packedfiles")).lazy.compactMap { $0.follow("packedfile") }.first }
        if let pf = packed, let b = f.block(at: pf.ptr("data")) {
            let size = min(pf.int("size"), b.size)
            let data = Data(f.bytes[b.offset ..< b.offset + max(size, 0)])
            if let src = CGImageSourceCreateWithData(data as CFData, nil), let image = ModelImport.image(src, opaque: opaque) { return image }
        }
        let p = path(img)
        guard !p.isEmpty else { return nil }
        func open(_ u: URL) -> RGBAImage? { CGImageSourceCreateWithURL(u as CFURL, nil).flatMap { ModelImport.image($0, opaque: opaque) } }
        if p.hasPrefix("//"), let u = ModelImport.existing(folder.appendingPathComponent(String(p.dropFirst(2)))).map(\.standardizedFileURL),
           let image = open(u) { return image }
        if p.hasPrefix("/"), let image = open(URL(fileURLWithPath: p)) { return image }
        // Elsewhere on the author's computer: look for the file name next to the .blend (and a few folders down).
        let file = URL(fileURLWithPath: p).lastPathComponent.lowercased()
        guard !file.isEmpty, let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return nil }
        for case let u as URL in walker {
            if walker.level > 3 { walker.skipDescendants(); continue }
            if u.lastPathComponent.lowercased() == file || ModelImport.ungarbled(u.lastPathComponent).contains(where: { $0.lowercased() == file }) {
                return open(u)
            }
        }
        return nil
    }

    /// "Avatar_Girl_Sword_Odette_Mat_Hair.001" → "Hair".
    static func partName(_ material: String) -> String {
        var s = material
        if let r = s.range(of: "_Mat_", options: .caseInsensitive) { s = String(s[r.upperBound...]) }
        if let dot = s.lastIndex(of: "."), s[s.index(after: dot)...].allSatisfy(\.isNumber) { s = String(s[..<dot]) }
        return s.isEmpty ? "Model" : s
    }

    // MARK: Skeleton

    static func segmentDistance(_ pLeague: SIMD3<Float>, _ b: Bone) -> Float {
        let p = SIMD3(-pLeague.x, -pLeague.z, pLeague.y) / 125          // back to Blender space
        let d = b.tail - b.head, l = simd_length_squared(d)
        let t = l > 0 ? min(max(simd_dot(p - b.head, d) / l, 0), 1) : 0
        return simd_distance(p, b.head + t * d)
    }

    /// The bones that move the model, with League-style names where the body part is known, and a hierarchy that follows
    /// the body: rigs like Auto-Rig Pro drive their deform bones by constraints, so they hang off control bones instead
    /// of each other, and split each limb into two halves (one of them a "twist") that are joined back here.
    /// `map`: armature bone → index in `bones`.
    static func cleanRig(_ all: [Bone], _ weightOf: [Float]) -> (bones: [Bone], map: [Int: Int]) {
        let used = all.indices.filter { weightOf[$0] > 0 }
        guard !used.isEmpty else { return ([Bone(name: "Root", parent: -1, head: .zero, tail: SIMD3(0, 0, 0.1))], [:]) }
        let lo = used.map { min(all[$0].head.z, all[$0].tail.z) }.min()!, hi = used.map { max(all[$0].head.z, all[$0].tail.z) }.max()!
        let height = max(hi - lo, 0.01)
        let canon = Dictionary(uniqueKeysWithValues: used.map { ($0, canonical(all[$0].name)) })

        // Parent: the nearest ancestor that moves the model, else (detached deform bones) the bone whose end is nearest its start.
        func usedAncestor(_ i: Int) -> Int? {
            var p = all[i].parent
            while p >= 0 { if weightOf[p] > 0 { return p }; p = all[p].parent }
            return nil
        }
        var parent: [Int: Int] = [:]
        var children: [Int: [Int]] = [:]
        var orphans: [Int] = []
        for i in used {
            if let a = usedAncestor(i) { parent[i] = a; children[a, default: []].append(i) } else { orphans.append(i) }
        }
        let root = orphans.filter { canon[$0]?.name == "Pelvis" }.max { weightOf[$0] < weightOf[$1] }
            ?? orphans.max { weightOf[$0] < weightOf[$1] }!
        parent[root] = -1
        var attached: [Int] = []
        func attach(_ i: Int) { attached.append(i); for c in children[i] ?? [] { attach(c) } }
        attach(root)
        // Detached bones join one at a time, closest pair first (an elbow hanging next to the hip still joins its upper arm).
        // Bones of a known body part are preferred (a spine joins the pelvis rather than a skirt bone ending nearby).
        func score(_ o: Int, _ c: Int) -> Float { simd_distance(all[o].head, all[c].tail) + (canon[c]!.name == all[c].name ? 0.1 * height : 0) }
        var waiting = orphans.filter { $0 != root }
        while !waiting.isEmpty {
            var best: (o: Int, c: Int, s: Float)?
            for o in waiting { for c in attached { let v = score(o, c); if v < best?.s ?? .infinity { best = (o, c, v) } } }
            guard let best else { break }
            parent[best.o] = best.c
            waiting.removeAll { $0 == best.o }
            attach(best.o)
        }

        // Join limb halves: a bone continuing its parent with the same body part (upper arm + its twist half…).
        var into: [Int: Int] = [:]
        func target(_ i: Int) -> Int { var t = i; while let n = into[t] { t = n }; return t }
        var tail: [Int: SIMD3<Float>] = [:]
        for i in attached {
            guard let p = parent[i], p >= 0, let c = canon[i], c.limb, let pc = canon[p], pc.name == c.name else { continue }
            let tp = target(p)
            guard simd_distance(all[i].head, tail[tp] ?? all[tp].tail) < 0.03 * height else { continue }
            into[i] = tp
            tail[tp] = all[i].tail
        }

        // Kept bones, parents first.
        var bones: [Bone] = [], map: [Int: Int] = [:]
        var taken = Set<String>()
        for i in attached where into[i] == nil {
            var p = parent[i] ?? -1
            if p >= 0 { p = target(p) }
            var name = canon[i]!.name
            // A twist helper keeps its own name (and stays a helper) unless the limb's other half was joined into it.
            if canon[i]!.twist && !into.values.contains(i) { name = all[i].name }
            var unique = name, k = 2
            while taken.contains(unique) { unique = "\(name)_\(k)"; k += 1 }
            taken.insert(unique)
            map[i] = bones.count
            bones.append(Bone(name: unique, parent: p >= 0 ? (map[p] ?? -1) : -1, head: all[i].head, tail: tail[i] ?? all[i].tail))
        }
        for i in attached where into[i] != nil { map[i] = map[target(i)] }
        return (bones, map)
    }

    /// Body parts found from the skeleton's shape when the bone names don't say (names lost to a converter, unknown rig
    /// conventions): the feet are the lowest heavy bones on each side and their chains up to the middle give the legs and
    /// pelvis; the hands are the farthest out, their chains giving clavicle, upper arm and forearm; the head is the
    /// heaviest bone at the top, and the middle bones between it and the chest are the neck and spine.
    static func inferBody(_ bones: inout [Bone], _ weight: [Float]) {
        let needed = ["Pelvis", "Head", "L_UpperArm", "R_UpperArm", "L_Forearm", "R_Forearm", "L_Hand", "R_Hand",
                      "L_Thigh", "R_Thigh", "L_Calf", "R_Calf", "L_Foot", "R_Foot"]
        let names = Set(bones.map(\.name))
        guard !needed.allSatisfy(names.contains), bones.count > 10 else { return }
        let zs = bones.map(\.head.z)
        let lo = zs.min()!, H = max(zs.max()! - lo, 0.01)
        let total = weight.reduce(0, +)
        func sig(_ i: Int) -> Bool { weight[i] > 0.002 * total }
        func center(_ i: Int) -> Bool { abs(bones[i].head.x) < 0.008 * H }
        func z(_ i: Int) -> Float { (bones[i].head.z - lo) / H }
        func chainToCenter(_ i: Int) -> (chain: [Int], center: Int?) {      // from i up, until a middle bone
            var out = [i], p = bones[i].parent
            while p >= 0 && !center(p) { out.append(p); p = bones[p].parent }
            return (out, p >= 0 ? p : nil)
        }
        var named: [Int: String] = [:]
        // Head
        guard let head = bones.indices.filter({ sig($0) && center($0) && z($0) > 0.75 }).max(by: { weight[$0] < weight[$1] }) else { return }
        named[head] = "Head"
        // Legs
        var pelvis: Int?
        for (side, sign) in [("L_", Float(1)), ("R_", Float(-1))] {
            guard let low = bones.indices.filter({ sig($0) && bones[$0].head.x * sign > 0.01 * H && z($0) < 0.15 })
                    .max(by: { weight[$0] < weight[$1] }) else { continue }
            let (chain, c) = chainToCenter(low)
            if ProcessInfo.processInfo.environment["SKINLAB_BLENDDEBUG"] != nil {
                print("leg \(side): " + chain.map { "\(bones[$0].name) z \(z($0)) x \(bones[$0].head.x / H) w \(weight[$0] / total)" }.joined(separator: " <- ") + " center \(c.map { bones[$0].name } ?? "-")")
            }
            guard chain.count >= 3, let thigh = chain.last else { continue }
            let rest = chain.dropLast()
            guard let foot = rest.min(by: { abs(z($0) - 0.055) < abs(z($1) - 0.055) }) else { continue }
            let kneeZ = (z(thigh) + z(foot)) / 2
            guard let calf = rest.filter({ $0 != foot }).min(by: { abs(z($0) - kneeZ) < abs(z($1) - kneeZ) }) else { continue }
            named[thigh] = side + "Thigh"; named[calf] = side + "Calf"; named[foot] = side + "Foot"
            if let toe = rest.filter({ z($0) < z(foot) && bones[$0].parent == foot }).max(by: { weight[$0] < weight[$1] }) { named[toe] = side + "Toe" }
            if pelvis == nil { pelvis = c }
        }
        if let pelvis { named[pelvis] = "Pelvis" }
        // The middle line from the head down to the pelvis.
        var path: [Int] = []
        var p = bones[head].parent
        while p >= 0 && p != pelvis { if center(p) { path.append(p) }; p = bones[p].parent }
        let line = Set(path + [head] + (pelvis.map { [$0] } ?? []))
        // Arms
        var chest: Int?
        for (side, sign) in [("L_", Float(1)), ("R_", Float(-1))] {
            guard let tip = bones.indices.filter({ sig($0) && z($0) > 0.3 && z($0) < 0.9 }).max(by: { bones[$0].head.x * sign < bones[$1].head.x * sign }),
                  bones[tip].head.x * sign > 0.1 * H else { continue }
            var up = [tip], q = bones[tip].parent
            while q >= 0 && !line.contains(q) { up.append(q); q = bones[q].parent }
            let c: Int? = q >= 0 ? q : nil
            let arm = Array(up.reversed())                     // from the middle out
            if ProcessInfo.processInfo.environment["SKINLAB_BLENDDEBUG"] != nil {
                print("arm \(side): center \(c.map { "\(bones[$0].name) z \(z($0))" } ?? "-") -> " + arm.map { "\(bones[$0].name) x \(bones[$0].head.x / H) z \(z($0)) w \(weight[$0] / total)" }.joined(separator: " -> "))
            }
            guard arm.count >= 3 else { continue }
            // The hand: where the fingers branch off, else most of the way out.
            let parents = bones.map(\.parent)
            func kids(_ i: Int) -> Int { parents.indices.filter { parents[$0] == i && sig($0) }.count }
            // (else the heaviest bone of the outer half: the hand holds the whole hand mesh)
            let handIndex = arm.indices.dropFirst(2).first { kids(arm[$0]) >= 3 }
                ?? arm.indices.dropFirst(max(2, arm.count / 2)).max { weight[arm[$0]] < weight[arm[$1]] } ?? arm.count - 1
            let hand = arm[min(handIndex, arm.count - 1)]
            let w = bones[hand].head
            func mid(_ a: SIMD3<Float>) -> SIMD3<Float> { (a + w) / 2 }
            let inner = Array(arm[..<min(handIndex, arm.count - 1)])
            guard inner.count >= 2 else { continue }
            let e0 = inner.dropFirst().min { simd_distance(bones[$0].head, mid(bones[inner[1]].head)) < simd_distance(bones[$1].head, mid(bones[inner[1]].head)) }!
            let forearmLength = simd_distance(bones[e0].head, w)
            let before = inner.prefix { $0 != e0 }
            guard let upper = before.min(by: { abs(simd_distance(bones[$0].head, bones[e0].head) - forearmLength)
                                              < abs(simd_distance(bones[$1].head, bones[e0].head) - forearmLength) }) else { continue }
            let after = inner.drop { $0 != upper }.dropFirst()
            let elbow = after.min { simd_distance(bones[$0].head, mid(bones[upper].head)) < simd_distance(bones[$1].head, mid(bones[upper].head)) } ?? e0
            named[upper] = side + "UpperArm"; named[elbow] = side + "Forearm"; named[hand] = side + "Hand"
            if let k = inner.firstIndex(of: upper), k > 0 { named[inner[k - 1]] = side + "Clavicle" }
            if chest == nil { chest = c }
        }
        // Neck and spine: the middle line under the head (lowest spine bone first).
        if path.count >= 2 {
            named[path[0]] = "Neck"
            for (n, i) in path.dropFirst().reversed().enumerated() where named[i] == nil { named[i] = "Spine\(n + 1)" }
        } else if let first = path.first {
            named[first] = "Spine1"
        }
        _ = chest
        // Other bones named like a body part (a necktie read as a neck…) become plain helpers.
        let roles = Porter.roles({ var sk = Skeleton(); sk.joints = bones.map { .init(name: $0.name, parent: $0.parent, bind: matrix_identity_float4x4, local: .zero, nameHash: 0) }; return sk }())
        var taken = Set(named.values)
        for i in bones.indices {
            if let n = named[i] { bones[i].name = n }
            else if roles[i] != nil || taken.contains(bones[i].name) { bones[i].name = "Ctl_" + bones[i].name }
        }
        taken = []
        for i in bones.indices { var n = bones[i].name, k = 2; while taken.contains(n) { n = bones[i].name + "_\(k)"; k += 1 }; bones[i].name = n; taken.insert(n) }
    }

    /// A bone's League-style name when its body part is known ("arm_stretch.l" → "L_UpperArm", "spine_02.x" → "Spine2",
    /// "DEF-thigh.R.001" → "R_Thigh"), else its own name. `limb`: halves of it may be joined; `twist`: a twist helper.
    static func canonical(_ raw: String) -> (name: String, limb: Bool, twist: Bool) {
        let name = raw.unicodeScalars.contains { !$0.isASCII } ? ModelImport.leagueNames([raw], weights: [1])[0] : raw
        var w = Porter.words(name)
        var side = ""
        if w.contains("l") || w.contains("left") { side = "L_" }
        if w.contains("r") || w.contains("right") { side = "R_" }
        let twist = w.contains { $0.contains("twist") }
        w.removeAll { ["l", "r", "left", "right", "x", "stretch", "offset", "deform", "twist", "fk", "ik"].contains($0) }
        let number = w.compactMap { Int($0) }.first
        let core = w.filter { Int($0) == nil }.joined()
        func limb(_ n: String) -> (String, Bool, Bool) { (side.isEmpty ? (raw, false, twist) : (side + n, true, twist)) }
        switch core {
        case "pelvis", "hips": return ("Pelvis", false, twist)
        case "root" where side.isEmpty: return ("Pelvis", false, twist)
        case "hip" where side.isEmpty: return ("Pelvis", false, twist)
        case "spine": return ("Spine" + (number.map(String.init) ?? ""), false, twist)
        case "chest", "upperchest": return ("Chest", false, twist)
        case "neck": return twist ? (raw, false, true) : ("Neck", false, false)
        case "head": return ("Head", false, twist)
        case "shoulder", "clavicle", "collarbone": return side.isEmpty ? (raw, false, twist) : (side + "Clavicle", false, twist)
        case "arm", "upperarm", "uparm": return limb("UpperArm")
        case "forearm", "lowerarm", "elbow": return limb("Forearm")
        case "hand", "wrist": return side.isEmpty ? (raw, false, twist) : (side + "Hand", false, twist)
        case "thigh", "upleg", "upperleg": return limb("Thigh")
        case "leg", "calf", "shin", "lowerleg", "knee": return limb("Calf")
        case "foot", "ankle": return side.isEmpty ? (raw, false, twist) : (side + "Foot", false, twist)
        case "toe", "toes", "toebase": return side.isEmpty ? (raw, false, twist) : (side + "Toe", false, twist)
        default: return (raw, false, twist)
        }
    }
}
