import Foundation
import ImageIO
import simd

/// Characters made outside League: MMD models (.pmx), the format of the official Genshin Impact character models and
/// most anime models. Read into a skin-like model (parts with their textures, a skeleton with League-style joint names)
/// that can be ported onto a champion like any skin.
enum ModelImport {
    struct Material {
        var name: String
        var texture: Int
        var indexCount: Int
    }

    /// MMD units are about 8 cm; League's about 1 cm (a champion is ~200 tall).
    static let scale: Float = 10

    /// A model in any format SkinLab reads, by its extension.
    static func loadAny(_ url: URL) throws -> SkinData {
        switch url.pathExtension.lowercased() {
        case "blend": return try BlendImport.load(url)
        case "gltf", "glb": return try GLTFImport.load(url)
        default: return try load(url)
        }
    }

    static func load(_ url: URL) throws -> SkinData {
        let data = try Data(contentsOf: url)
        guard data.starts(with: Data("PMX ".utf8)) else {
            throw FormatError(data.starts(with: Data("Pmd".utf8)) ? "Old .pmd models aren't supported: save it as .pmx (PMX Editor) first"
                                                                  : "Not a .pmx model")
        }
        var r = PMXReader(data)
        r.pos = 8
        let globalCount = Int(try r.u8())
        var g = [Int](repeating: 0, count: max(globalCount, 8))
        for i in 0 ..< globalCount { g[i] = Int(try r.u8()) }
        r.utf16 = g[0] == 0
        let extraUV = g[1], vertexSize = g[2], textureSize = g[3], materialSize = g[4], boneSize = g[5]
        _ = materialSize
        let name = try r.text()
        _ = try r.text(); _ = try r.text(); _ = try r.text()

        // Vertices
        var mesh = SkinnedMesh()
        var vertexBones: [[(Int, Float)]] = []
        let vertexCount = Int(try r.i32())
        guard vertexCount > 0, vertexCount < 2_000_000 else { throw FormatError("This model has no vertices") }
        for _ in 0 ..< vertexCount {
            let p = try r.vec3(), n = try r.vec3()
            let uv = SIMD2(try r.f32(), try r.f32())
            try r.skip(16 * extraUV)
            var bones: [(Int, Float)] = []
            switch try r.u8() {
            case 0: bones = [(try r.index(boneSize), 1)]
            case 1:
                let a = try r.index(boneSize), b = try r.index(boneSize), w = try r.f32()
                bones = [(a, w), (b, 1 - w)]
            case 2, 4:
                let ids = try (0 ..< 4).map { _ in try r.index(boneSize) }
                let ws = try (0 ..< 4).map { _ in try r.f32() }
                bones = Array(zip(ids, ws))
            case 3:
                let a = try r.index(boneSize), b = try r.index(boneSize), w = try r.f32()
                try r.skip(36)
                bones = [(a, w), (b, 1 - w)]
            default: throw FormatError("Unknown vertex weight type")
            }
            _ = try r.f32()                                                     // edge scale
            // MMD faces -Z, League +Z: turned half a turn (same handedness).
            mesh.positions.append(SIMD3(-p.x, p.y, -p.z) * scale)
            mesh.normals.append(SIMD3(-n.x, n.y, -n.z))
            mesh.uvs.append(uv)
            vertexBones.append(bones.filter { $0.0 >= 0 && $0.1 > 0 })
        }
        // Faces
        let indexCount = Int(try r.i32())
        var indices: [Int] = []
        indices.reserveCapacity(indexCount)
        for _ in 0 ..< indexCount { indices.append(try r.vertexIndex(vertexSize)) }
        // Textures
        var texturePaths: [String] = []
        for _ in 0 ..< Int(try r.i32()) { texturePaths.append(try r.text().replacingOccurrences(of: "\\", with: "/")) }
        // Materials
        var materials: [Material] = []
        for i in 0 ..< Int(try r.i32()) {
            var mname = try r.text()
            _ = try r.text()
            try r.skip(16 + 12 + 4 + 12 + 1 + 16 + 4)                           // colors, flags, edge
            let tex = try r.index(textureSize)
            _ = try r.index(textureSize)                                       // sphere map
            _ = try r.u8()
            let sharedToon = try r.u8()
            if sharedToon == 1 { _ = try r.u8() } else { _ = try r.index(textureSize) }
            _ = try r.text()
            let count = Int(try r.i32())
            if mname.trimmingCharacters(in: .whitespaces).isEmpty { mname = "Mat\(i)" }
            materials.append(Material(name: mname, texture: tex, indexCount: count))
        }
        // Bones
        var boneNames: [String] = [], parents: [Int] = [], positions: [SIMD3<Float>] = []
        for _ in 0 ..< Int(try r.i32()) {
            boneNames.append(try r.text())
            _ = try r.text()
            let p = try r.vec3()
            positions.append(SIMD3(-p.x, p.y, -p.z) * scale)
            parents.append(try r.index(boneSize))
            _ = try r.i32()                                                     // layer
            let flags = Int(try r.u16())
            if flags & 0x0001 != 0 { _ = try r.index(boneSize) } else { try r.skip(12) }
            if flags & 0x0300 != 0 { _ = try r.index(boneSize); try r.skip(4) }
            if flags & 0x0400 != 0 { try r.skip(12) }
            if flags & 0x0800 != 0 { try r.skip(24) }
            if flags & 0x2000 != 0 { try r.skip(4) }
            if flags & 0x0020 != 0 {
                _ = try r.index(boneSize); try r.skip(8)
                for _ in 0 ..< Int(try r.i32()) {
                    _ = try r.index(boneSize)
                    if try r.u8() == 1 { try r.skip(24) }
                }
            }
        }
        guard !boneNames.isEmpty else { throw FormatError("This model has no bones") }

        // Skeleton with League-style names (the porter finds body parts by name).
        let (sk, bi, bw) = rig(names: leagueNames(boneNames, weights: boneWeights(vertexBones, count: boneNames.count)),
                               parents: parents, positions: positions, vertexBones: vertexBones)
        mesh.boneIndices = bi
        mesh.weights = bw

        // Parts (one per material) with their textures.
        let folder = url.deletingLastPathComponent()
        var parts: [Part] = []
        var start = 0
        for m in materials {
            let end = min(start + m.indexCount, indices.count)
            defer { start = end }
            guard end - start >= 3 else { continue }
            var tris: [SIMD3<Int32>] = []
            for t in stride(from: start, to: end - 2, by: 3) where indices[t] < vertexCount && indices[t + 1] < vertexCount && indices[t + 2] < vertexCount {
                tris.append(SIMD3(Int32(indices[t]), Int32(indices[t + 1]), Int32(indices[t + 2])))
            }
            parts.append(Part(name: m.name, triangles: tris, texture: m.texture >= 0 && m.texture < texturePaths.count ? "\(m.texture)" : nil))
        }
        return try assemble(mesh, parts: parts, skeleton: sk, name: name, source: url) { key in
            image(folder.appendingPathComponent(texturePaths[Int(key)!]))
        }
    }

    static func boneWeights(_ vertexBones: [[(Int, Float)]], count: Int) -> [Float] {
        var weightOf = [Float](repeating: 0, count: count)
        for vb in vertexBones { for (b, w) in vb where b < count { weightOf[b] += w } }
        return weightOf
    }

    /// The skeleton (bones named for the porter) and each vertex's 4 bones, from the model's bones (positions in League
    /// space) and each vertex's weights.
    static func rig(names: [String], parents: [Int], positions: [SIMD3<Float>],
                    vertexBones: [[(Int, Float)]]) -> (Skeleton, [SIMD4<UInt8>], [SIMD4<Float>]) {
        var names = names
        var weightOf = boneWeights(vertexBones, count: names.count)
        var boneIndices: [SIMD4<UInt8>] = [], weights: [SIMD4<Float>] = []
        func build(_ names: [String]) -> Skeleton {
            var sk = Skeleton()
            for (i, n) in names.enumerated() {
                var m = matrix_identity_float4x4
                m.columns.3 = SIMD4(positions[i], 1)
                let parent = parents[i] >= 0 && parents[i] < names.count && parents[i] != i ? parents[i] : -1
                sk.joints.append(.init(name: n, parent: parent, bind: m, local: positions[i] - (parent >= 0 ? positions[parent] : .zero),
                                       nameHash: Skeleton.elf(n)))
            }
            return sk
        }
        // MMD rigs often have several bones per limb (deform, control, IK helper…): the body part goes to the one
        // that moves the most of the model; the others become controls the porter ignores.
        let roles = Porter.roles(build(names))
        var groups: [Porter.RoleInfo: [Int]] = [:]
        for (i, r) in roles.enumerated() { if let r, ![.spine, .neck].contains(r.role) { groups[r, default: []].append(i) } }
        for (_, members) in groups where members.count > 1 {
            guard let winner = members.max(by: { weightOf[$0] < weightOf[$1] }), weightOf[winner] > 0 else { continue }
            for i in members where i != winner { names[i] = "Ctl_" + names[i] }
        }
        var sk = build(names)
        // Model bone slots (max 256): the weighted bones; if there are more, the lightest fold into their parents.
        var used = Set(vertexBones.flatMap { $0.map(\.0) }.filter { $0 < sk.joints.count })
        var redirect = [Int](sk.joints.indices)
        while used.count > 255 {
            guard let lightest = used.min(by: { weightOf[$0] < weightOf[$1] }) else { break }
            used.remove(lightest)
            var p = sk.joints[lightest].parent
            while p >= 0 && !used.contains(p) { p = sk.joints[p].parent }
            let to = p >= 0 ? p : (used.first ?? 0)
            for j in redirect.indices where redirect[j] == lightest { redirect[j] = to }
            weightOf[to] += weightOf[lightest]
        }
        sk.influences = used.sorted()
        let slot = Dictionary(uniqueKeysWithValues: sk.influences.enumerated().map { ($1, $0) })
        for vb in vertexBones {
            var merged: [Int: Float] = [:]
            for (b, w) in vb where b < redirect.count { merged[redirect[b], default: 0] += w }
            let top = merged.sorted { $0.value > $1.value }.prefix(4)
            let sum = top.reduce(0) { $0 + $1.value }
            var bi = SIMD4<UInt8>(0, 0, 0, 0), bw = SIMD4<Float>(0, 0, 0, 0)
            for (k, e) in top.enumerated() { bi[k] = UInt8(slot[e.key] ?? 0); bw[k] = sum > 0 ? e.value / sum : 0 }
            if top.isEmpty { bw[0] = 1 }
            boneIndices.append(bi)
            weights.append(bw)
        }

        return (sk, boneIndices, weights)
    }

    struct Part {
        var name: String
        var triangles: [SIMD3<Int32>]
        var texture: String?        // key passed to `texture` in assemble
    }

    /// The finished model: parts named uniquely, each texture loaded once, simplified if too detailed for League.
    static func assemble(_ mesh: SkinnedMesh, parts: [Part], skeleton sk: Skeleton, name: String, source url: URL,
                         texture: (String) -> RGBAImage?) throws -> SkinData {
        let safe = String(url.deletingPathExtension().lastPathComponent.lowercased().filter { $0.isLetter || $0.isNumber }.prefix(24))
        var partTexture: [String: UInt64] = [:]
        var textures: [UInt64: (data: Data, image: RGBAImage)] = [:]
        var order: [UInt64] = []
        var loaded: [String: UInt64?] = [:]
        var usedNames = Set<String>()
        var named: [(name: String, triangles: [SIMD3<Int32>])] = []
        for p in parts {
            var partName = p.name
            var k = 2
            while usedNames.contains(partName) { partName = "\(p.name)_\(k)"; k += 1 }
            usedNames.insert(partName)
            named.append((partName, p.triangles))
            guard let key = p.texture else { continue }
            if loaded[key] == nil {
                if let img = texture(key) {
                    let h = pathHash("skinlab/import/\(safe)/\(key).tex")
                    textures[h] = (TextureFile.newTex(img), img)
                    order.append(h)
                    loaded[key] = h
                } else {
                    loaded[key] = .some(nil)
                }
            }
            if let h = loaded[key] ?? nil { partTexture[partName] = h }
        }
        let input = Simplify.Input(positions: mesh.positions, normals: mesh.normals, uvs: mesh.uvs, boneIndices: mesh.boneIndices,
                                   weights: mesh.weights, parts: named)
        // League models hold at most 65,535 vertices: detailed models are simplified to fit (with some room).
        let forced = ProcessInfo.processInfo.environment["SKINLAB_SIMPLIFY"].flatMap { Int($0) }     // debug: simplify further
        let vertexCount = mesh.positions.count
        let out = Simplify.run(input, target: forced ?? (vertexCount > 65535 ? 60000 : Int.max))
        guard out.positions.count <= 65535 else {
            throw FormatError("This model is too detailed (\(vertexCount) points) even after simplifying")
        }
        return finish(out, sk, partTexture, textures, order, name)
    }

    private static func finish(_ mesh: SkinnedMesh, _ sk: Skeleton, _ partTexture: [String: UInt64],
                               _ textures: [UInt64: (data: Data, image: RGBAImage)], _ order: [UInt64], _ name: String) -> SkinData {
        var mesh = mesh
        // League's winding: cross(b - a, c - a) along the normals.
        var along = 0, against = 0
        for t in stride(from: 0, to: mesh.indices.count - 2, by: 3) {
            let a = Int(mesh.indices[t]), b = Int(mesh.indices[t + 1]), c = Int(mesh.indices[t + 2])
            let n = simd_cross(mesh.positions[b] - mesh.positions[a], mesh.positions[c] - mesh.positions[a])
            if simd_dot(n, mesh.normals[a] + mesh.normals[b] + mesh.normals[c]) > 0 { along += 1 } else { against += 1 }
        }
        if against > along { for t in stride(from: 0, to: mesh.indices.count - 2, by: 3) { mesh.indices.swapAt(t + 1, t + 2) } }
        return SkinData(bin: BinFile(), propsIndex: 0, mesh: mesh, skeleton: sk, skeletonData: nil, partTexture: partTexture,
                        textures: textures, textureOrder: order, hideAtStart: [])
    }

    /// A texture file (png, jpg, bmp, tga…), at most 1024 wide (League textures are rarely bigger).
    static func image(_ url: URL) -> RGBAImage? {
        guard let u = existing(url), let src = CGImageSourceCreateWithURL(u as CFURL, nil) else { return nil }
        return image(src)
    }

    /// `opaque`: the alpha channel isn't transparency (game textures often keep masks there) and is dropped, keeping the
    /// colors under it.
    static func image(_ src: CGImageSource, opaque: Bool = false) -> RGBAImage? {
        guard var cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        if opaque, let o = withoutAlpha(cg) { cg = o }
        let k = min(1, 1024 / Float(max(cg.width, cg.height)))
        return RGBAImage(cgImage: cg, width: max(1, Int(Float(cg.width) * k)), height: max(1, Int(Float(cg.height) * k)))
    }

    /// The image with its alpha channel dropped: read from its own pixels (drawing it would blacken colors under alpha 0).
    static func withoutAlpha(_ cg: CGImage) -> CGImage? {
        let info = cg.alphaInfo
        if [.none, .noneSkipLast, .noneSkipFirst].contains(info) { return cg }
        let bpc = cg.bitsPerComponent, comps = cg.bitsPerPixel / max(bpc, 1)
        guard bpc == 8 || bpc == 16, comps == 4 || comps == 2, let data = cg.dataProvider?.data as Data? else { return nil }
        let w = cg.width, h = cg.height, row = cg.bytesPerRow, size = bpc / 8
        let order = cg.bitmapInfo.intersection(.byteOrderMask)
        let little = order == .byteOrder32Little || order == .byteOrder16Little
        let alphaFirst = info == .first || info == .premultipliedFirst, premultiplied = info == .premultipliedFirst || info == .premultipliedLast
        guard data.count >= row * h else { return nil }
        var out = [UInt8](repeating: 255, count: w * h * 4)
        data.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            for y in 0 ..< h {
                for x in 0 ..< w {
                    let base = y * row + x * comps * size
                    // Components in memory order (8-bit little-endian pixels are stored reversed).
                    func comp(_ k: Int) -> Int {
                        let kk = bpc == 8 && little && comps == 4 ? 3 - k : k
                        let o = base + kk * size
                        return size == 1 ? Int(p[o]) : Int(p[o + (little ? 1 : 0)])         // high byte of 16-bit values
                    }
                    var c: [Int]
                    let a: Int
                    if comps == 4 {
                        c = alphaFirst ? [comp(1), comp(2), comp(3)] : [comp(0), comp(1), comp(2)]
                        a = alphaFirst ? comp(0) : comp(3)
                    } else {
                        c = alphaFirst ? [comp(1), comp(1), comp(1)] : [comp(0), comp(0), comp(0)]
                        a = alphaFirst ? comp(0) : comp(1)
                    }
                    if premultiplied && a > 0 && a < 255 { c = c.map { min(255, $0 * 255 / a) } }
                    let o = (y * w + x) * 4
                    out[o] = UInt8(c[0]); out[o + 1] = UInt8(c[1]); out[o + 2] = UInt8(c[2])
                }
            }
        }
        let space = comps == 4 ? (cg.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!) : CGColorSpace(name: CGColorSpace.sRGB)!
        guard let provider = CGDataProvider(data: Data(out) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }

    /// The file a model names, found even when its name on disk differs: other letter case (Windows), or Chinese / Japanese
    /// names garbled when the model's zip was extracted on a Mac ("体.png" saved as "ÃÂ.png").
    static func existing(_ url: URL) -> URL? {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { return url }
        var dir = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) { guard let d = existing(dir) else { return nil }; dir = d }
        let wanted = url.lastPathComponent.precomposedStringWithCanonicalMapping.lowercased()
        guard let entries = try? fm.contentsOfDirectory(atPath: dir.path) else { return nil }
        let match = entries.first { $0.precomposedStringWithCanonicalMapping.lowercased() == wanted }
            ?? entries.first { e in ungarbled(e).contains { $0.lowercased() == wanted } }
        return match.map { dir.appendingPathComponent($0) }
    }

    /// What a garbled file name may have been: its bytes read as Chinese (GBK, Big5), Japanese (Shift JIS) or Korean, whether
    /// the unzip kept the raw bytes or read them as Mac Roman / DOS text.
    static func ungarbled(_ name: String) -> [String] {
        let n = name.precomposedStringWithCanonicalMapping
        func enc(_ e: CFStringEncodings) -> String.Encoding { String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(e.rawValue))) }
        let asian: [String.Encoding] = [enc(.GB_18030_2000), .shiftJIS, enc(.big5), enc(.EUC_KR)]
        var raws: [Data] = [Data(n.utf8)]
        for e in [String.Encoding.macOSRoman, enc(.dosLatinUS), .isoLatin1, .windowsCP1252] { if let d = n.data(using: e) { raws.append(d) } }
        var out: [String] = []
        for raw in raws { for e in asian { if let s = String(data: raw, encoding: e), s != n { out.append(s.precomposedStringWithCanonicalMapping) } } }
        return out
    }

    /// MMD bone names (Japanese) → names the porter knows: 左腕 → L_UpperArm, 右ひざ → R_Calf, 下半身 → Pelvis…
    /// When a model has deform copies (足D, ひざD…) carrying the weights, those get the body-part names.
    static func leagueNames(_ jp: [String], weights: [Float]) -> [String] {
        let table: [(String, String)] = [
            ("全ての親", "AllParent"), ("センター", "Center"), ("グルーブ", "Groove"), ("腰キャンセル", "WaistCancel"), ("腰", "Waist"),
            ("下半身", "Pelvis"), ("上半身3", "Spine3"), ("上半身2", "Spine2"), ("上半身", "Spine1"), ("首", "Neck"), ("頭", "Head"),
            ("両目", "Eyes"), ("目", "Eye"), ("肩P", "ShoulderP"), ("肩C", "ShoulderC"), ("肩", "Clavicle"),
            ("腕捩", "ArmTwist"), ("手捩", "WristTwist"), ("腕", "UpperArm"), ("ひじ", "Elbow"), ("手首", "Hand"),
            ("親指", "Thumb"), ("人指", "Index"), ("中指", "Middle"), ("薬指", "Ring"), ("小指", "Pinky"),
            ("足首", "Foot"), ("足先EX", "ToeEX"), ("つま先", "Toe"), ("ひざ", "Calf"), ("足", "Thigh"),
            ("髪", "Hair"), ("前髪", "Bangs"), ("スカート", "Skirt"), ("胸", "Breast"), ("乳", "Breast"), ("袖", "Sleeve"), ("リボン", "Ribbon"),
            ("ＩＫ", "IK"), ("IK", "IK"), ("先", "Tip"), ("操作中心", "ControlCenter"), ("ダミー", "Dummy"), ("剣", "Sword"), ("刀", "Katana"),
            ("武器", "Weapon"), ("槍", "Spear"), ("弓", "Bow"),
        ]
        func translate(_ s: String) -> String {
            var rest = s.replacingOccurrences(of: "．", with: ".")
            var side = ""
            if rest.hasPrefix("左") { side = "L_"; rest.removeFirst() } else if rest.hasPrefix("右") { side = "R_"; rest.removeFirst() }
            var out = ""
            var deform = false
            if rest.hasSuffix("D") && !rest.hasSuffix("IKD") { deform = true; rest.removeLast() }
            while !rest.isEmpty {
                if let (jp, en) = table.first(where: { rest.hasPrefix($0.0) }) {
                    out += (out.isEmpty ? "" : "_") + en
                    rest.removeFirst(jp.count)
                } else if let c = rest.first, c.isASCII && (c.isLetter || c.isNumber || c == "_" || c == ".") {
                    out.append(c); rest.removeFirst()
                } else if let c = rest.first, let v = c.wholeNumberValue {
                    out.append(String(v)); rest.removeFirst()          // full-width digits
                } else {
                    rest.removeFirst()
                }
            }
            if out.isEmpty { out = "Bone" }
            return side + out + (deform ? "_D" : "")
        }
        var names = jp.map(translate)
        // Deform copies with the weights take the body-part name; the originals become controls.
        for i in names.indices where names[i].hasSuffix("_D") {
            let base = String(names[i].dropLast(2))
            if let j = names.firstIndex(of: base) {
                if weights[i] >= weights[j] { names[j] = base + "Ctl"; names[i] = base }
            } else {
                names[i] = base
            }
        }
        // Unique names (ELF hashes must differ): of bones with the same name, the one moving the most of the model keeps it,
        // the others become controls (so a body part never goes to an empty helper bone).
        var byName: [String: [Int]] = [:]
        for (i, n) in names.enumerated() { byName[n, default: []].append(i) }
        for (n, members) in byName where members.count > 1 {
            let ranked = members.sorted { weights[$0] != weights[$1] ? weights[$0] > weights[$1] : $0 < $1 }
            for (k, i) in ranked.enumerated().dropFirst() { names[i] = k == 1 ? "Ctl_\(n)" : "Ctl_\(n)_\(k)" }
        }
        var seen = Set<String>()
        return names.enumerated().map { i, n in
            var name = n
            var k = 2
            while seen.contains(name) { name = "\(n)_x\(k)"; k += 1 }
            seen.insert(name)
            return name
        }
    }
}

/// Reads PMX's little-endian values, texts and variable-size indices.
struct PMXReader {
    let d: [UInt8]
    var pos = 0
    var utf16 = true
    init(_ data: Data) { d = [UInt8](data) }

    mutating func need(_ n: Int) throws { guard pos + n <= d.count else { throw FormatError("The model file is cut short") } }
    mutating func skip(_ n: Int) throws { try need(n); pos += n }
    mutating func u8() throws -> UInt8 { try need(1); pos += 1; return d[pos - 1] }
    mutating func u16() throws -> UInt16 { try need(2); pos += 2; return UInt16(d[pos - 2]) | UInt16(d[pos - 1]) << 8 }
    mutating func u32() throws -> UInt32 {
        try need(4); pos += 4
        return UInt32(d[pos - 4]) | UInt32(d[pos - 3]) << 8 | UInt32(d[pos - 2]) << 16 | UInt32(d[pos - 1]) << 24
    }
    mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }
    mutating func f32() throws -> Float { Float(bitPattern: try u32()) }
    mutating func vec3() throws -> SIMD3<Float> { SIMD3(try f32(), try f32(), try f32()) }
    mutating func text() throws -> String {
        let n = Int(try i32())
        guard n >= 0 else { throw FormatError("Bad text in the model file") }
        try need(n)
        let bytes = Data(d[pos ..< pos + n])
        pos += n
        return String(data: bytes, encoding: utf16 ? .utf16LittleEndian : .utf8) ?? ""
    }
    /// Bone / texture / material indices: signed (-1 = none).
    mutating func index(_ size: Int) throws -> Int {
        switch size {
        case 1: return Int(Int8(bitPattern: try u8()))
        case 2: return Int(Int16(bitPattern: try u16()))
        default: return Int(try i32())
        }
    }
    /// Vertex indices: unsigned for 1 and 2 bytes.
    mutating func vertexIndex(_ size: Int) throws -> Int {
        switch size {
        case 1: return Int(try u8())
        case 2: return Int(try u16())
        default: return Int(try i32())
        }
    }
}
