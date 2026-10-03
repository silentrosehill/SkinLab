import Foundation
import CoreGraphics
import simd

/// Builds a rough, rigged, textured model from a character sheet's views:
/// carve the space every view's silhouette allows, turn it into a smooth surface,
/// paint it by projecting each view back on, and give it a League-style skeleton.
enum Reconstruct {
    static let height: Float = 180

    struct Calibrated {
        let view: SheetView
        var theta: Float          // radians
        var scale: Float          // pixels per unit
        var shift: Float = 0      // correction of the body axis column
        let dilated: [Bool]

        /// Pixel of a point in this view (real-world frame: +x is the character's left, +z its front).
        func pixel(_ p: SIMD3<Float>, mirrored: Bool = false) -> SIMD2<Float> {
            let t = mirrored ? -theta : theta
            var u = p.x * cos(t) - p.z * sin(t)
            if mirrored { u = -u }
            return SIMD2(view.axis + shift + u * scale, Float(view.top) + (Reconstruct.height - p.y) * scale)
        }

        func covers(_ p: SIMD3<Float>) -> Bool {
            let px = pixel(p)
            let c = Int(px.x), r = Int(px.y)
            return c >= 0 && r >= 0 && c < view.width && r < view.height && dilated[r * view.width + c]
        }
    }

    static func calibrate(_ v: SheetView, dilate: Int = 2) -> Calibrated {
        var d = v.mask
        for _ in 0 ..< dilate {
            var next = d
            for y in 0 ..< v.height {
                for x in 0 ..< v.width where !d[y * v.width + x] {
                    if (x > 0 && d[y * v.width + x - 1]) || (x < v.width - 1 && d[y * v.width + x + 1])
                        || (y > 0 && d[(y - 1) * v.width + x]) || (y < v.height - 1 && d[(y + 1) * v.width + x]) {
                        next[y * v.width + x] = true
                    }
                }
            }
            d = next
        }
        return Calibrated(view: v, theta: v.angle * .pi / 180, scale: Float(v.bottom - v.top) / height, dilated: d)
    }

    /// Lines up the in-between views with the front and side: tries angles (either direction around the character),
    /// offsets and sizes, and keeps what matches the shape the front and side already agree on.
    static func autoCalibrate(_ cal: [Calibrated]) -> [Calibrated] {
        guard let front = cal.first(where: { $0.view.angle == 0 }),
              let sideIndex = cal.firstIndex(where: { abs($0.view.angle) == 90 }) else { return cal }
        let H = height, c = H / 64, half = 0.62 * H
        func hull(_ views: [Calibrated]) -> [SIMD3<Float>] {
            var pts: [SIMD3<Float>] = []
            var z = -half
            while z < half {
                var y: Float = 0
                while y < H {
                    var x = -half
                    while x < half {
                        let p = SIMD3(x, y, z)
                        if views.allSatisfy({ $0.covers(p) }) { pts.append(p) }
                        x += c
                    }
                    y += c
                }
                z += c
            }
            return pts
        }
        /// How well the shape's outline matches a view (intersection over union, at quarter size).
        func score(_ pts: [SIMD3<Float>], _ v: Calibrated) -> Float {
            let w = v.view.width / 4 + 1, h = v.view.height / 4 + 1
            var proj = [Bool](repeating: false, count: w * h)
            for p in pts {
                let px = v.pixel(p)
                let cx = Int(px.x / 4), cy = Int(px.y / 4)
                for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
                    let x = cx + dx, y = cy + dy
                    if x >= 0, y >= 0, x < w, y < h { proj[y * w + x] = true }
                }
            }
            var inter = 0, union = 0
            for y in 0 ..< h {
                for x in 0 ..< w {
                    let m = v.view.inside(x * 4, y * 4)
                    if m && proj[y * w + x] { inter += 1 }
                    if m || proj[y * w + x] { union += 1 }
                }
            }
            return union > 0 ? Float(inter) / Float(union) : 0
        }

        var best: (total: Float, cal: [Calibrated]) = (-1, cal)
        for sideSign: Float in [-1, 1] {
            var trial = cal
            trial[sideIndex].theta = sideSign * .pi / 2
            let pts = hull([front, trial[sideIndex]])
            var total: Float = 0
            for i in trial.indices where abs(trial[i].view.angle) == 45 || abs(trial[i].view.angle) == 135 {
                let base = abs(trial[i].view.angle)
                var bestView = trial[i], bestScore: Float = -1
                for sign: Float in [-1, 1] {
                    for a in stride(from: base - 20, through: base + 20, by: 5) {
                        for shift in stride(from: Float(-30), through: 30, by: 3) {
                            var v = trial[i]
                            v.theta = sign * a * .pi / 180
                            v.shift = shift
                            let sc = score(pts, v)
                            if sc > bestScore { bestScore = sc; bestView = v }
                        }
                    }
                }
                let baseScale = bestView.scale
                for f: Float in [0.9, 0.95, 1.05, 1.1] {
                    var v = bestView
                    v.scale = baseScale * f
                    let sc = score(pts, v)
                    if sc > bestScore { bestScore = sc; bestView = v }
                }
                trial[i] = bestView
                total += bestScore
            }
            if total > best.total { best = (total, trial) }
        }
        // The back view faces the other way from the front: keep it, its axis follows the front's.
        return best.cal
    }

    static func build(_ views: [SheetView], name: String, resolution: Int = 128) throws -> SkinData {
        var cal = autoCalibrate(views.map { calibrate($0) })
        if ProcessInfo.processInfo.environment["SKINLAB_DEBUG"] != nil {
            for v in cal { print("\(v.view.label): angle \(v.theta * 180 / .pi) shift \(v.shift) scale \(v.scale)") }
        }
        cal = cal.map { $0 }
        let env = ProcessInfo.processInfo.environment
        let carveAngles = env["SKINLAB_CARVE"].map { $0.split(separator: ",").compactMap { Float($0) } } ?? [0, -45, -90, -135]
        let carvers = cal.filter { carveAngles.contains($0.view.angle) || (carveAngles.contains(-45) && abs($0.view.angle) == 45)
            || (carveAngles.contains(-135) && abs($0.view.angle) == 135) || (carveAngles.contains(-90) && abs($0.view.angle) == 90) }
        let H = height

        // 1. Carve: keep every voxel all silhouettes agree on.
        let c = H / Float(resolution)
        let half = 0.62 * H
        let nx = Int(2 * half / c) + 2, nz = nx, ny = resolution + 4
        let origin = SIMD3<Float>(-half - c, -2 * c, -half - c)
        var occ = [Bool](repeating: false, count: nx * ny * nz)
        func idx(_ i: Int, _ j: Int, _ k: Int) -> Int { (k * ny + j) * nx + i }
        for k in 1 ..< nz - 1 {
            for j in 1 ..< ny - 1 {
                for i in 1 ..< nx - 1 {
                    let p = origin + SIMD3(Float(i) + 0.5, Float(j) + 0.5, Float(k) + 0.5) * c
                    var inside = true
                    for v in carvers where !v.covers(p) { inside = false; break }
                    occ[idx(i, j, k)] = inside
                }
            }
        }

        // 2. Surface nets: one vertex per surface cell, one quad per crossing edge.
        var cellVertex = [Int32](repeating: -1, count: nx * ny * nz)
        var positions: [SIMD3<Float>] = []
        for k in 0 ..< nz - 1 {
            for j in 0 ..< ny - 1 {
                for i in 0 ..< nx - 1 {
                    var sum = SIMD3<Float>(0, 0, 0), n: Float = 0
                    let corners = (0 ..< 8).map { b in occ[idx(i + (b & 1), j + (b >> 1 & 1), k + (b >> 2 & 1))] }
                    if corners.allSatisfy({ $0 == corners[0] }) { continue }
                    for (a, b) in [(0, 1), (2, 3), (4, 5), (6, 7), (0, 2), (1, 3), (4, 6), (5, 7), (0, 4), (1, 5), (2, 6), (3, 7)]
                    where corners[a] != corners[b] {
                        let pa = SIMD3(Float(a & 1), Float(a >> 1 & 1), Float(a >> 2 & 1))
                        let pb = SIMD3(Float(b & 1), Float(b >> 1 & 1), Float(b >> 2 & 1))
                        sum += (pa + pb) / 2
                        n += 1
                    }
                    cellVertex[idx(i, j, k)] = Int32(positions.count)
                    positions.append(origin + (SIMD3(Float(i), Float(j), Float(k)) + SIMD3(repeating: 0.5) + sum / n) * c)
                }
            }
        }
        var tris: [Int] = []
        func quad(_ a: Int, _ b: Int, _ cc: Int, _ d: Int, flip: Bool) {
            let q = [a, b, cc, d].map { Int(cellVertex[$0]) }
            guard !q.contains(-1) else { return }
            if flip { tris += [q[0], q[2], q[1], q[0], q[3], q[2]] } else { tris += [q[0], q[1], q[2], q[0], q[2], q[3]] }
        }
        for k in 1 ..< nz - 1 {
            for j in 1 ..< ny - 1 {
                for i in 1 ..< nx - 1 {
                    let here = occ[idx(i, j, k)]
                    if i + 1 < nx, here != occ[idx(i + 1, j, k)] {
                        quad(idx(i, j - 1, k - 1), idx(i, j, k - 1), idx(i, j, k), idx(i, j - 1, k), flip: !here)
                    }
                    if j + 1 < ny, here != occ[idx(i, j + 1, k)] {
                        quad(idx(i - 1, j, k - 1), idx(i - 1, j, k), idx(i, j, k), idx(i, j, k - 1), flip: !here)
                    }
                    if k + 1 < nz, here != occ[idx(i, j, k + 1)] {
                        quad(idx(i - 1, j - 1, k), idx(i, j - 1, k), idx(i, j, k), idx(i - 1, j, k), flip: !here)
                    }
                }
            }
        }
        guard !tris.isEmpty else { throw FormatError("The views didn't agree on a shape") }

        // Keep the main piece: drop specks the silhouettes disagree about.
        (positions, tris) = largestPieces(positions, tris)

        // 3. Smooth (Taubin: smooths without shrinking).
        var neighbors = [Set<Int>](repeating: [], count: positions.count)
        for t in stride(from: 0, to: tris.count, by: 3) {
            for (a, b) in [(0, 1), (1, 2), (2, 0)] { neighbors[tris[t + a]].insert(tris[t + b]); neighbors[tris[t + b]].insert(tris[t + a]) }
        }
        for pass in 0 ..< 12 {
            let f: Float = pass % 2 == 0 ? 0.5 : -0.53
            positions = positions.indices.map { v in
                guard !neighbors[v].isEmpty else { return positions[v] }
                let avg = neighbors[v].reduce(SIMD3<Float>(0, 0, 0)) { $0 + positions[$1] } / Float(neighbors[v].count)
                return positions[v] + f * (avg - positions[v])
            }
        }
        if signedVolume(positions, tris) < 0 {
            for t in stride(from: 0, to: tris.count, by: 3) { tris.swapAt(t + 1, t + 2) }
        }
        let normals = vertexNormals(positions, tris)

        // 4. Paint: each triangle takes the view facing it most (the unseen side mirrors the seen one).
        let atlas = Atlas(cal)
        struct Cam { let cal: Calibrated; let mirrored: Bool; let dir: SIMD3<Float>; let slot: Int }
        var cams: [Cam] = []
        for (s, v) in cal.enumerated() {
            let t = v.theta
            cams.append(Cam(cal: v, mirrored: false, dir: SIMD3(sin(t), 0, cos(t)), slot: s))
            if v.view.angle != 0 && v.view.angle != 180 {
                cams.append(Cam(cal: v, mirrored: true, dir: SIMD3(sin(-t), 0, cos(-t)), slot: s))
            }
        }
        let triCount = tris.count / 3
        var choice = (0 ..< triCount).map { t -> Int in
            let n = simd_normalize(normals[tris[t * 3]] + normals[tris[t * 3 + 1]] + normals[tris[t * 3 + 2]])
            return cams.indices.max { simd_dot(n, cams[$0].dir) < simd_dot(n, cams[$1].dir) }!
        }
        // Tidy the patchwork: a triangle follows the view most of its neighbors use.
        var triNeighbors = [[Int]](repeating: [], count: triCount)
        var byEdge: [UInt64: [Int]] = [:]
        for t in 0 ..< triCount {
            for (a, b) in [(0, 1), (1, 2), (2, 0)] {
                let x = tris[t * 3 + a], y = tris[t * 3 + b]
                byEdge[UInt64(min(x, y)) << 32 | UInt64(max(x, y)), default: []].append(t)
            }
        }
        for list in byEdge.values where list.count == 2 { triNeighbors[list[0]].append(list[1]); triNeighbors[list[1]].append(list[0]) }
        for _ in 0 ..< 2 {
            choice = (0 ..< triCount).map { t in
                var votes: [Int: Int] = [choice[t]: 1]
                for n in triNeighbors[t] { votes[choice[n], default: 0] += 1 }
                let best = votes.max { $0.value < $1.value }!
                return best.value >= 3 ? best.key : choice[t]
            }
        }

        // 5. Skeleton from the front view's proportions, and bone weights by distance.
        let skeleton = makeSkeleton(cal.first { $0.view.angle == 0 }!)
        let bones = boneSegments(skeleton)

        var mesh = SkinnedMesh()
        var remap: [Int: Int] = [:]   // (vertex, camera) → new vertex
        for t in 0 ..< triCount {
            let cam = cams[choice[t]]
            for v in tris[t * 3 ..< t * 3 + 3] {
                let key = v * 16 + choice[t]
                if let existing = remap[key] { mesh.indices.append(UInt16(existing)); continue }
                let p = positions[v]
                let px = cam.cal.pixel(p, mirrored: cam.mirrored)
                let uv = atlas.uv(slot: cam.slot, px: px, view: cam.cal.view)
                // Into League's frame: mirrored X (the character's left at -x).
                let lp = SIMD3(-p.x, p.y, p.z)
                mesh.positions.append(lp)
                mesh.normals.append(SIMD3(-normals[v].x, normals[v].y, normals[v].z))
                mesh.uvs.append(uv)
                let (bi, bw) = weights(lp, bones)
                mesh.boneIndices.append(bi)
                mesh.weights.append(bw)
                remap[key] = mesh.positions.count - 1
                mesh.indices.append(UInt16(mesh.positions.count - 1))
                guard mesh.positions.count < 65000 else { throw FormatError("The shape came out too detailed") }
            }
        }
        // The X mirror flips which way triangles face.
        for t in stride(from: 0, to: mesh.indices.count, by: 3) { mesh.indices.swapAt(t + 1, t + 2) }
        mesh.parts = [.init(name: "Body", startIndex: 0, indexCount: mesh.indices.count)]

        let textureHash = pathHash("skinlab/sheet/\(name).tex")
        let texData = TextureFile.newTex(atlas.image)
        return SkinData(bin: BinFile(), propsIndex: 0, mesh: mesh, skeleton: skeleton, skeletonData: nil, partTexture: ["Body": textureHash],
                        textures: [textureHash: (texData, atlas.image)], textureOrder: [textureHash], hideAtStart: [])
    }

    // MARK: Helpers

    private static func signedVolume(_ p: [SIMD3<Float>], _ t: [Int]) -> Float {
        stride(from: 0, to: t.count, by: 3).reduce(0) { $0 + simd_dot(p[t[$1]], simd_cross(p[t[$1 + 1]], p[t[$1 + 2]])) }
    }

    private static func vertexNormals(_ p: [SIMD3<Float>], _ t: [Int]) -> [SIMD3<Float>] {
        var n = [SIMD3<Float>](repeating: .zero, count: p.count)
        for i in stride(from: 0, to: t.count, by: 3) {
            let f = simd_cross(p[t[i + 1]] - p[t[i]], p[t[i + 2]] - p[t[i]])
            n[t[i]] += f; n[t[i + 1]] += f; n[t[i + 2]] += f
        }
        return n.map { simd_length($0) > 0 ? simd_normalize($0) : SIMD3(0, 1, 0) }
    }

    /// Pieces of the surface with at least 3% of the biggest one's triangles.
    private static func largestPieces(_ p: [SIMD3<Float>], _ t: [Int]) -> ([SIMD3<Float>], [Int]) {
        var parent = Array(p.indices)
        func find(_ x: Int) -> Int { var x = x; while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }; return x }
        for i in stride(from: 0, to: t.count, by: 3) {
            let a = find(t[i]), b = find(t[i + 1]), c = find(t[i + 2])
            parent[b] = a; parent[find(c)] = a
        }
        var size: [Int: Int] = [:]
        for i in stride(from: 0, to: t.count, by: 3) { size[find(t[i]), default: 0] += 1 }
        let biggest = size.values.max() ?? 0
        let keep = Set(size.filter { $0.value * 33 >= biggest }.keys)
        var newIndex = [Int](repeating: -1, count: p.count)
        var outP: [SIMD3<Float>] = []
        var outT: [Int] = []
        for i in stride(from: 0, to: t.count, by: 3) where keep.contains(find(t[i])) {
            for v in t[i ..< i + 3] {
                if newIndex[v] < 0 { newIndex[v] = outP.count; outP.append(p[v]) }
                outT.append(newIndex[v])
            }
        }
        return (outP, outT)
    }

    /// Joints placed by typical body proportions, with the arms reaching the front silhouette's hands.
    private static func makeSkeleton(_ front: Calibrated) -> Skeleton {
        let H = height, v = front.view
        // Hand tips: the furthest character pixels left and right in the upper body.
        var tipL = SIMD3<Float>(0.45 * H, 0.75 * H, 0), tipR = SIMD3<Float>(-0.45 * H, 0.75 * H, 0)
        let rowFrom = Int(Float(v.top) + 0.12 * H * front.scale), rowTo = Int(Float(v.top) + 0.5 * H * front.scale)
        var minCol = Int.max, maxCol = Int.min, minRow = 0, maxRow = 0
        for r in max(0, rowFrom) ..< min(v.height, rowTo) {
            for col in 0 ..< v.width where v.mask[r * v.width + col] {
                if col < minCol { minCol = col; minRow = r }
                if col > maxCol { maxCol = col; maxRow = r }
            }
        }
        func world(_ col: Int, _ row: Int) -> SIMD3<Float> {
            SIMD3((Float(col) - v.axis) / front.scale, H - (Float(row) - Float(v.top)) / front.scale, 0)
        }
        if maxCol > Int.min { tipL = world(maxCol, maxRow); tipR = world(minCol, minRow) }

        // Real-world frame here (+x = the character's left); converted to League's below.
        var joints: [(String, Int, SIMD3<Float>)] = []
        func add(_ name: String, _ parent: Int, _ p: SIMD3<Float>) -> Int { joints.append((name, parent, p)); return joints.count - 1 }
        let pelvis = add("Pelvis", -1, SIMD3(0, 0.53 * H, 0))
        let spine1 = add("Spine1", pelvis, SIMD3(0, 0.6 * H, 0))
        let spine2 = add("Spine2", spine1, SIMD3(0, 0.7 * H, 0))
        let neck = add("Neck", spine2, SIMD3(0, 0.84 * H, 0))
        _ = add("Head", neck, SIMD3(0, 0.885 * H, 0))
        for (side, sign, tip) in [("L", Float(1), tipL), ("R", Float(-1), tipR)] {
            let clav = add("\(side)_Clavicle", spine2, SIMD3(sign * 0.02 * H, 0.82 * H, 0))
            let sh = SIMD3(sign * 0.1 * H, 0.81 * H, 0)
            let shoulder = add("\(side)_Shoulder", clav, sh)
            let elbow = add("\(side)_Elbow", shoulder, sh + 0.45 * (tip - sh))
            _ = add("\(side)_Hand", elbow, sh + 0.86 * (tip - sh))
            let hip = add("\(side)_Hip", pelvis, SIMD3(sign * 0.055 * H, 0.5 * H, 0))
            let kneeU = add("\(side)_KneeUpper", hip, SIMD3(sign * 0.06 * H, 0.28 * H, 0.01 * H))
            let kneeL = add("\(side)_KneeLower", kneeU, SIMD3(sign * 0.06 * H, 0.28 * H, 0.01 * H))
            let foot = add("\(side)_Foot", kneeL, SIMD3(sign * 0.065 * H, 0.045 * H, -0.01 * H))
            _ = add("\(side)_Toe", foot, SIMD3(sign * 0.065 * H, 0.01 * H, 0.06 * H))
        }
        var sk = Skeleton()
        for (name, parent, p) in joints {
            var m = matrix_identity_float4x4
            m.columns.3 = SIMD4(-p.x, p.y, p.z, 1)
            sk.joints.append(.init(name: name, parent: parent, bind: m))
        }
        sk.influences = Array(sk.joints.indices)
        return sk
    }

    /// Each joint's bone: from the joint to its first child (or a short way past it for hands, head, toes).
    private static func boneSegments(_ sk: Skeleton) -> [(joint: Int, a: SIMD3<Float>, b: SIMD3<Float>)] {
        sk.joints.indices.map { j in
            let a = sk.joints[j].position
            if let child = sk.joints.indices.first(where: { sk.joints[$0].parent == j && simd_distance(sk.joints[$0].position, a) > 0.5 }) {
                return (j, a, sk.joints[child].position)
            }
            let p = sk.joints[j].parent
            let dir = p >= 0 ? simd_normalize(a - sk.joints[p].position + SIMD3(0, 0.0001, 0)) : SIMD3(0, 1, 0)
            let name = sk.joints[j].name.lowercased()
            let len: Float = name == "head" ? 0.12 * height : name.hasSuffix("hand") ? 0.1 * height : 0.04 * height
            return (j, a, a + dir * len)
        }
    }

    private static func weights(_ p: SIMD3<Float>, _ bones: [(joint: Int, a: SIMD3<Float>, b: SIMD3<Float>)]) -> (SIMD4<UInt8>, SIMD4<Float>) {
        var d: [(Int, Float)] = bones.map { bone in
            let ab = bone.b - bone.a
            let t = simd_clamp(simd_dot(p - bone.a, ab) / max(simd_length_squared(ab), 0.0001), 0, 1)
            return (bone.joint, simd_distance(p, bone.a + t * ab))
        }
        d.sort { $0.1 < $1.1 }
        let near = d.prefix(2)
        let w = near.map { 1 / (pow($0.1, 4) + 0.01) }
        let sum = w.reduce(0, +)
        var bi = SIMD4<UInt8>(0, 0, 0, 0), bw = SIMD4<Float>(0, 0, 0, 0)
        for (k, e) in near.enumerated() { bi[k] = UInt8(e.0); bw[k] = w[k] / sum }
        return (bi, bw)
    }

    /// The views packed into one texture: the front big on the left, the others beside it.
    struct Atlas {
        let image: RGBAImage
        let slots: [CGRect]          // in pixels, top-left origin

        init(_ cal: [Calibrated]) {
            let W = 2048, H = 1024
            var px = [UInt8](repeating: 0, count: W * H * 4)
            var slots: [CGRect] = []
            var x = 0
            for c in cal {
                let w = c.view.angle == 0 ? 512 : 384, h = c.view.angle == 0 ? 1024 : 768
                let rect = CGRect(x: x, y: 0, width: w, height: h)
                x += w
                slots.append(rect)
                guard x <= W else { continue }
                let filled = Atlas.bleed(c.view)
                guard let small = RGBAImage(cgImage: filled, width: w, height: h) else { continue }
                for row in 0 ..< h {
                    for col in 0 ..< w {
                        let s = (row * w + col) * 4, d = (row * W + Int(rect.minX) + col) * 4
                        px[d] = small.pixels[s]; px[d + 1] = small.pixels[s + 1]; px[d + 2] = small.pixels[s + 2]; px[d + 3] = 255
                    }
                }
            }
            image = RGBAImage(width: W, height: H, pixels: px)
            self.slots = slots
        }

        func uv(slot: Int, px: SIMD2<Float>, view: SheetView) -> SIMD2<Float> {
            let r = slots[slot]
            let u = Float(r.minX) + simd_clamp(px.x / Float(view.width), 0, 1) * Float(r.width)
            let v = Float(r.minY) + simd_clamp(px.y / Float(view.height), 0, 1) * Float(r.height)
            return SIMD2(u / Float(image.width), v / Float(image.height))
        }

        /// The view with the character's colors spread outward over the background, so edges don't pick up the backdrop.
        static func bleed(_ v: SheetView) -> CGImage {
            guard var img = RGBAImage(cgImage: v.image, width: v.width, height: v.height) else { return v.image }
            var known = v.mask
            for _ in 0 ..< 10 {
                var next = known
                var px = img.pixels
                for y in 0 ..< v.height {
                    for x in 0 ..< v.width where !known[y * v.width + x] {
                        var sum = SIMD3<Int>(0, 0, 0), n = 0
                        for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                            let xx = x + dx, yy = y + dy
                            guard xx >= 0, yy >= 0, xx < v.width, yy < v.height, known[yy * v.width + xx] else { continue }
                            let o = (yy * v.width + xx) * 4
                            sum &+= SIMD3(Int(img.pixels[o]), Int(img.pixels[o + 1]), Int(img.pixels[o + 2]))
                            n += 1
                        }
                        if n > 0 {
                            let o = (y * v.width + x) * 4
                            px[o] = UInt8(sum.x / n); px[o + 1] = UInt8(sum.y / n); px[o + 2] = UInt8(sum.z / n)
                            next[y * v.width + x] = true
                        }
                    }
                }
                img.pixels = px
                known = next
            }
            return img.cgImage ?? v.image
        }
    }
}

extension TextureFile {
    /// A new .tex (uncompressed, with mipmaps) for an image.
    static func newTex(_ image: RGBAImage) -> Data {
        var header = Data("TEX\0".utf8)
        header.append(contentsOf: [0, 0, 0, 0, 1, 20, 0, 1])
        return encode(image, like: header)
    }
}
