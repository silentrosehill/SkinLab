import Foundation
import ImageIO
import simd

/// glTF 2.0 models (.gltf with its .bin and textures, or a single .glb), the common exchange format (Sketchfab, VRoid /
/// VRM, Blender and most 3D tools export it). Every mesh of the scene comes in with its skin weights and each
/// material's base color texture; the skeleton is cleaned up and named for the porter like a Blender rig.
enum GLTFImport {
    static func load(_ url: URL) throws -> SkinData {
        let file = try Data(contentsOf: url)
        var jsonData = file
        var glbBinary: Data?
        if file.starts(with: Data("glTF".utf8)) {               // .glb: header, JSON chunk, binary chunk
            jsonData = Data()
            var p = 12
            while p + 8 <= file.count {
                let length = Int(u32(file, p)), type = u32(file, p + 4)
                guard p + 8 + length <= file.count else { break }
                let chunk = file.subdata(in: p + 8 ..< p + 8 + length)
                if type == 0x4E4F_534A { jsonData = chunk } else if type == 0x004E_4942 { glbBinary = chunk }
                p += 8 + length
            }
        }
        guard let json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { throw FormatError("Not a glTF model") }
        let g = Doc(json: json, folder: url.deletingLastPathComponent(), glb: glbBinary)
        return try g.model(url)
    }

    static func u32(_ d: Data, _ o: Int) -> UInt32 {
        d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) }
    }

    private struct Doc {
        let json: [String: Any]
        let folder: URL
        let glb: Data?
        var buffers: [Data] = []

        init(json: [String: Any], folder: URL, glb: Data?) {
            self.json = json
            self.folder = folder
            self.glb = glb
            buffers = list("buffers").enumerated().map { i, b in
                guard let uri = b["uri"] as? String else { return i == 0 ? (glb ?? Data()) : Data() }
                return Self.data(uri: uri, folder: folder) ?? Data()
            }
        }

        func list(_ key: String) -> [[String: Any]] { json[key] as? [[String: Any]] ?? [] }

        static func data(uri: String, folder: URL) -> Data? {
            if uri.hasPrefix("data:") {
                guard let comma = uri.firstIndex(of: ",") else { return nil }
                return Data(base64Encoded: String(uri[uri.index(after: comma)...]))
            }
            let path = uri.removingPercentEncoding ?? uri
            return ModelImport.existing(folder.appendingPathComponent(path)).flatMap { try? Data(contentsOf: $0) }
        }

        func bufferView(_ i: Int) -> (data: Data, offset: Int, length: Int, stride: Int)? {
            let views = list("bufferViews")
            guard views.indices.contains(i), let b = views[i]["buffer"] as? Int, buffers.indices.contains(b) else { return nil }
            let v = views[i]
            return (buffers[b], v["byteOffset"] as? Int ?? 0, v["byteLength"] as? Int ?? 0, v["byteStride"] as? Int ?? 0)
        }

        /// An accessor's values as floats, `components` per element (normalized integers scaled to 0…1 / -1…1).
        func floats(_ index: Int?) -> (values: [Float], components: Int) {
            let accessors = list("accessors")
            guard let index, accessors.indices.contains(index) else { return ([], 0) }
            let a = accessors[index]
            let count = a["count"] as? Int ?? 0
            let comps = ["SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT2": 4, "MAT3": 9, "MAT4": 16][a["type"] as? String ?? ""] ?? 1
            let type = a["componentType"] as? Int ?? 5126
            let normalized = a["normalized"] as? Bool ?? false
            let size = [5120: 1, 5121: 1, 5122: 2, 5123: 2, 5125: 4, 5126: 4][type] ?? 4
            var out = [Float](repeating: 0, count: count * comps)
            guard let viewIndex = a["bufferView"] as? Int, let view = bufferView(viewIndex) else { return (out, comps) }   // all zeros
            let stride = view.stride > 0 ? view.stride : size * comps
            let base = view.offset + (a["byteOffset"] as? Int ?? 0)
            view.data.withUnsafeBytes { raw in
                for e in 0 ..< count {
                    for c in 0 ..< comps {
                        let o = base + e * stride + c * size
                        guard o + size <= raw.count else { return }
                        let v: Float
                        switch type {
                        case 5120: let x = Float(raw.load(fromByteOffset: o, as: Int8.self)); v = normalized ? max(x / 127, -1) : x
                        case 5121: let x = Float(raw.load(fromByteOffset: o, as: UInt8.self)); v = normalized ? x / 255 : x
                        case 5122: let x = Float(raw.loadUnaligned(fromByteOffset: o, as: Int16.self)); v = normalized ? max(x / 32767, -1) : x
                        case 5123: let x = Float(raw.loadUnaligned(fromByteOffset: o, as: UInt16.self)); v = normalized ? x / 65535 : x
                        case 5125: v = Float(raw.loadUnaligned(fromByteOffset: o, as: UInt32.self))
                        default: v = raw.loadUnaligned(fromByteOffset: o, as: Float.self)
                        }
                        out[e * comps + c] = v
                    }
                }
            }
            return (out, comps)
        }

        func ints(_ index: Int?) -> [Int] { floats(index).values.map { Int($0) } }

        func localMatrix(_ n: [String: Any]) -> simd_float4x4 {
            if let m = (n["matrix"] as? [NSNumber])?.map(\.floatValue), m.count == 16 {
                return simd_float4x4(SIMD4(m[0], m[1], m[2], m[3]), SIMD4(m[4], m[5], m[6], m[7]), SIMD4(m[8], m[9], m[10], m[11]),
                                     SIMD4(m[12], m[13], m[14], m[15]))
            }
            let t = (n["translation"] as? [NSNumber])?.map(\.floatValue) ?? [0, 0, 0]
            let r = (n["rotation"] as? [NSNumber])?.map(\.floatValue) ?? [0, 0, 0, 1]
            let s = (n["scale"] as? [NSNumber])?.map(\.floatValue) ?? [1, 1, 1]
            let q = simd_quatf(ix: r[0], iy: r[1], iz: r[2], r: r[3])
            let rs = simd_float3x3(simd_length(q.vector) > 0 ? simd_normalize(q) : simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)))
                * simd_float3x3(diagonal: SIMD3(s[0], s[1], s[2]))
            return simd_float4x4(SIMD4(rs.columns.0, 0), SIMD4(rs.columns.1, 0), SIMD4(rs.columns.2, 0), SIMD4(t[0], t[1], t[2], 1))
        }

        /// The base color texture of a material (or a swatch of its color), with its alpha kept only when the material
        /// is see-through.
        func texture(material m: [String: Any]) -> RGBAImage? {
            let pbr = m["pbrMetallicRoughness"] as? [String: Any]
            let specGloss = (m["extensions"] as? [String: Any])?["KHR_materials_pbrSpecularGlossiness"] as? [String: Any]
            let info = pbr?["baseColorTexture"] as? [String: Any] ?? specGloss?["diffuseTexture"] as? [String: Any]
            let opaque = (m["alphaMode"] as? String ?? "OPAQUE") == "OPAQUE"
            if let t = info?["index"] as? Int, list("textures").indices.contains(t) {
                let tex = list("textures")[t]
                let ext = tex["extensions"] as? [String: Any]
                let source = tex["source"] as? Int
                    ?? (ext?["EXT_texture_webp"] as? [String: Any])?["source"] as? Int
                    ?? (ext?["KHR_texture_basisu"] as? [String: Any])?["source"] as? Int
                if let source, list("images").indices.contains(source) {
                    let img = list("images")[source]
                    var data: Data?
                    if let uri = img["uri"] as? String { data = Self.data(uri: uri, folder: folder) }
                    else if let v = img["bufferView"] as? Int, let view = bufferView(v), view.offset + view.length <= view.data.count {
                        data = view.data.subdata(in: view.offset ..< view.offset + view.length)
                    }
                    if let data, let src = CGImageSourceCreateWithData(data as CFData, nil), let image = ModelImport.image(src, opaque: opaque) {
                        return image
                    }
                }
            }
            // No texture: the material's color.
            let f = ((pbr?["baseColorFactor"] ?? specGloss?["diffuseFactor"]) as? [NSNumber])?.map(\.floatValue)
            guard let f, f.count >= 3 else { return nil }
            func srgb(_ c: Float) -> UInt8 { UInt8(min(max(c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055, 0), 1) * 255) }
            return RGBAImage(width: 4, height: 4, pixels: Array([srgb(f[0]), srgb(f[1]), srgb(f[2]), 255].repeated(16)))
        }

        func model(_ url: URL) throws -> SkinData {
            let nodes = list("nodes"), meshes = list("meshes"), skins = list("skins"), materials = list("materials")
            guard !meshes.isEmpty else { throw FormatError("This glTF file has no model") }

            // Scene placement of every node (rest pose).
            var world = [simd_float4x4](repeating: matrix_identity_float4x4, count: nodes.count)
            var parentOf = [Int](repeating: -1, count: nodes.count)
            for (i, n) in nodes.enumerated() { for c in n["children"] as? [Int] ?? [] where nodes.indices.contains(c) { parentOf[c] = i } }
            let scenes = list("scenes")
            var roots = (scenes.indices.contains(json["scene"] as? Int ?? 0) ? scenes[json["scene"] as? Int ?? 0]["nodes"] as? [Int] : nil)
                ?? nodes.indices.filter { parentOf[$0] < 0 }
            roots = roots.filter { nodes.indices.contains($0) }
            var inScene = [Bool](repeating: false, count: nodes.count)
            func place(_ i: Int, _ parent: simd_float4x4, depth: Int) {
                guard depth < 256, !inScene[i] else { return }
                inScene[i] = true
                world[i] = parent * localMatrix(nodes[i])
                for c in nodes[i]["children"] as? [Int] ?? [] where nodes.indices.contains(c) { place(c, world[i], depth: depth + 1) }
            }
            for r in roots { place(r, matrix_identity_float4x4, depth: 0) }

            // Units: meters normally; a model over 20 units tall is taken to be in centimeters.
            func toBlender(_ p: SIMD3<Float>) -> SIMD3<Float> { SIMD3(p.x, -p.z, p.y) }       // glTF: Y up, facing +Z
            var allY: [Float] = []
            for (i, n) in nodes.enumerated() where inScene[i] {
                guard let m = n["mesh"] as? Int, meshes.indices.contains(m) else { continue }
                for prim in meshes[m]["primitives"] as? [[String: Any]] ?? [] {
                    let pos = floats((prim["attributes"] as? [String: Any])?["POSITION"] as? Int).values
                    for k in stride(from: 1, to: pos.count, by: 3 * 7) {
                        let w = world[i] * SIMD4(pos[k - 1], pos[k], pos[k + 1], 1)
                        allY.append(w.y)
                    }
                }
            }
            // Sizes vary (meters, centimeters, MMD units scaled down…): a model outside 0.5–3 tall is scaled to 1.6.
            let height = (allY.max() ?? 0) - (allY.min() ?? 0)
            let unit: Float = height > 0 && (height < 0.5 || height > 3) ? 1.6 / height : 1

            // Bones: the joints of every skin.
            var boneOf: [Int: Int] = [:]
            var jointNodes: [Int] = []
            for s in skins { for j in s["joints"] as? [Int] ?? [] where nodes.indices.contains(j) && boneOf[j] == nil { boneOf[j] = jointNodes.count; jointNodes.append(j) } }
            // Sketchfab adds "_<node number>" to every name.
            let rawNames = jointNodes.map { nodes[$0]["name"] as? String ?? "" }
            let numbered = rawNames.filter { $0.range(of: #"_\d+$"#, options: .regularExpression) != nil }.count > rawNames.count * 3 / 4
            func jointName(_ node: Int, _ b: Int) -> String {
                var n = nodes[node]["name"] as? String ?? ""
                if numbered, let r = n.range(of: #"_\d+$"#, options: .regularExpression) { n.removeSubrange(r) }
                return n.isEmpty || n.contains("\u{FFFD}") ? "Joint\(b)" : n
            }
            var bones: [BlendImport.Bone] = jointNodes.enumerated().map { b, node in
                var p = parentOf[node]
                while p >= 0 && boneOf[p] == nil { p = parentOf[p] }
                let head = toBlender(SIMD3(world[node].columns.3.x, world[node].columns.3.y, world[node].columns.3.z) * unit)
                return BlendImport.Bone(name: jointName(node, b), parent: p >= 0 ? boneOf[p]! : -1, head: head, tail: head)
            }
            for b in bones.indices {          // tail: toward the children, else continuing the parent
                let kids = bones.indices.filter { bones[$0].parent == b }
                if !kids.isEmpty { bones[b].tail = kids.map { bones[$0].head }.reduce(.zero, +) / Float(kids.count) }
                else if bones[b].parent >= 0 { bones[b].tail = bones[b].head + (bones[b].head - bones[bones[b].parent].head) * 0.3 }
                if simd_distance(bones[b].tail, bones[b].head) < 1e-4 { bones[b].tail = bones[b].head + SIMD3(0, 0, 0.02) }
            }
            if bones.isEmpty { bones = [BlendImport.Bone(name: "Root", parent: -1, head: .zero, tail: SIMD3(0, 0, 0.1))] }

            var mesh = SkinnedMesh()
            var vertexBones: [[(Int, Float)]] = []
            var parts: [ModelImport.Part] = []
            var partOf: [Int: Int] = [:]
            var textures: [String: RGBAImage] = [:]
            for (i, n) in nodes.enumerated() where inScene[i] {
                guard let m = n["mesh"] as? Int, meshes.indices.contains(m) else { continue }
                let skin = (n["skin"] as? Int).flatMap { skins.indices.contains($0) ? skins[$0] : nil }
                let joints = skin?["joints"] as? [Int] ?? []
                let ibm = floats(skin?["inverseBindMatrices"] as? Int).values
                let jointMatrix: [simd_float4x4] = joints.enumerated().map { k, j in
                    guard nodes.indices.contains(j) else { return matrix_identity_float4x4 }
                    var inv = matrix_identity_float4x4
                    if ibm.count >= 16 * (k + 1) {
                        let v = Array(ibm[16 * k ..< 16 * k + 16])
                        inv = simd_float4x4(SIMD4(v[0], v[1], v[2], v[3]), SIMD4(v[4], v[5], v[6], v[7]), SIMD4(v[8], v[9], v[10], v[11]), SIMD4(v[12], v[13], v[14], v[15]))
                    }
                    return world[j] * inv
                }
                // An unskinned mesh follows the bone it hangs from (a prop), if any.
                var hangs = parentOf[i]
                while hangs >= 0 && boneOf[hangs] == nil { hangs = parentOf[hangs] }
                let morphWeights = (meshes[m]["weights"] as? [NSNumber])?.map(\.floatValue) ?? []

                for prim in meshes[m]["primitives"] as? [[String: Any]] ?? [] {
                    let mode = prim["mode"] as? Int ?? 4
                    guard [4, 5, 6].contains(mode), let attrs = prim["attributes"] as? [String: Any] else { continue }
                    var pos = floats(attrs["POSITION"] as? Int).values
                    let count = pos.count / 3
                    guard count > 0 else { continue }
                    // Shape keys at the values the file sets.
                    for (t, target) in (prim["targets"] as? [[String: Any]] ?? []).enumerated() where t < morphWeights.count && morphWeights[t] != 0 {
                        let d = floats(target["POSITION"] as? Int).values
                        if d.count == pos.count { for k in pos.indices { pos[k] += morphWeights[t] * d[k] } }
                    }
                    let uv = floats(attrs["TEXCOORD_0"] as? Int).values
                    let js = floats(attrs["JOINTS_0"] as? Int).values, ws = floats(attrs["WEIGHTS_0"] as? Int).values
                    let js1 = floats(attrs["JOINTS_1"] as? Int).values, ws1 = floats(attrs["WEIGHTS_1"] as? Int).values
                    var idx = attrs["POSITION"] != nil && prim["indices"] != nil ? ints(prim["indices"] as? Int) : Array(0 ..< count)
                    if mode == 5 { idx = idx.count < 3 ? [] : (0 ..< idx.count - 2).flatMap { k in k % 2 == 0 ? [idx[k], idx[k + 1], idx[k + 2]] : [idx[k + 1], idx[k], idx[k + 2]] } }
                    if mode == 6 { idx = idx.count < 3 ? [] : (1 ..< idx.count - 1).flatMap { k in [idx[0], idx[k], idx[k + 1]] } }

                    let base = mesh.positions.count
                    var placed: [SIMD3<Float>] = []
                    for v in 0 ..< count {
                        let p = SIMD4(pos[3 * v], pos[3 * v + 1], pos[3 * v + 2], 1)
                        var influences: [(Int, Float)] = []
                        func add(_ j: [Float], _ w: [Float]) {
                            guard j.count >= 4 * count, w.count >= 4 * count else { return }
                            for k in 0 ..< 4 where w[4 * v + k] > 0 { influences.append((Int(j[4 * v + k]), w[4 * v + k])) }
                        }
                        add(js, ws); add(js1, ws1)
                        var bind: SIMD4<Float>
                        if skin != nil, !influences.isEmpty {
                            bind = .zero
                            var total: Float = 0
                            for (j, w) in influences where jointMatrix.indices.contains(j) { bind += w * (jointMatrix[j] * p); total += w }
                            bind = total > 0 ? bind / total : world[i] * p
                        } else {
                            bind = world[i] * p
                        }
                        let b = toBlender(SIMD3(bind.x, bind.y, bind.z) * unit)
                        placed.append(b)
                        mesh.positions.append(BlendImport.league(b))
                        mesh.uvs.append(uv.count >= 2 * count ? SIMD2(uv[2 * v], uv[2 * v + 1]) : .zero)
                        if skin != nil {
                            vertexBones.append(influences.compactMap { j, w in joints.indices.contains(j) ? boneOf[joints[j]].map { ($0, w) } : nil })
                        } else {
                            vertexBones.append(hangs >= 0 ? [(boneOf[hangs]!, Float(1))] : [])
                        }
                    }
                    // Smooth normals from the faces (in Blender space, then League's).
                    var vn = [SIMD3<Float>](repeating: .zero, count: count)
                    var tris: [SIMD3<Int32>] = []
                    for t in stride(from: 0, to: idx.count - 2, by: 3) {
                        let a = idx[t], b = idx[t + 1], c = idx[t + 2]
                        guard a < count, b < count, c < count, a >= 0, b >= 0, c >= 0 else { continue }
                        // glTF front faces are counter-clockwise (Blender space is only turned, not mirrored).
                        let nrm = simd_cross(placed[b] - placed[a], placed[c] - placed[a])
                        vn[a] += nrm; vn[b] += nrm; vn[c] += nrm
                        tris.append(SIMD3(Int32(base + a), Int32(base + b), Int32(base + c)))
                    }
                    for n in vn { let u = simd_length(n) > 0 ? simd_normalize(n) : SIMD3<Float>(0, 0, 1); mesh.normals.append(SIMD3(-u.x, u.z, -u.y)) }

                    let mat = prim["material"] as? Int ?? -1
                    if partOf[mat] == nil {
                        let md = materials.indices.contains(mat) ? materials[mat] : [:]
                        let key = "\(mat + 1)"
                        if let img = texture(material: md) { textures[key] = img }
                        partOf[mat] = parts.count
                        let name = (md["name"] as? String).map(BlendImport.partName) ?? (mat >= 0 ? "Material\(mat)" : "Model")
                        parts.append(ModelImport.Part(name: name, triangles: [], texture: textures[key] != nil ? key : nil))
                    }
                    parts[partOf[mat]!].triangles += tris
                    guard mesh.positions.count < 2_000_000 else { throw FormatError("This glTF model is too big") }
                }
            }
            guard !mesh.positions.isEmpty else { throw FormatError("This glTF file has no triangles") }
            return try BlendImport.finish(mesh, bones: bones, vertexBones: vertexBones, parts: parts.filter { !$0.triangles.isEmpty },
                                          textures: textures, source: url)
        }
    }
}

private extension Array {
    func repeated(_ n: Int) -> [Element] { (0 ..< n).flatMap { _ in self } }
}
