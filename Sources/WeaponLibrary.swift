import Foundation
import SwiftUI
import UniformTypeIdentifiers
import simd

/// How Camille swings a weapon on Q: like Zaahen with his spear, or like the Ayaka skin with her katana.
enum WeaponStyle: String, Codable, CaseIterable, Identifiable {
    case spear, sword
    var id: String { rawValue }
    var title: String { self == .spear ? "Spear" : "Sword" }
    var moves: String { self == .spear ? "Zaahen's Q1 and Q2" : "Ayaka's Q (katana)" }

    /// The skin whose grip, carry and Q moves this style uses.
    var defaultFile: String { self == .spear ? "Flins_Zaahen-Main.fantome" : "Kamisato Ayaka Yasuo V1.0 by The Melancholy Of Slime.fantome" }
    var part: String { self == .spear ? "weapon" : "Sword" }
    var q: (String, String) { self == .spear ? ("Spell1_AA1.Zaahen", "Spell1_AA2.Zaahen") : ("spell1A", "spell1B") }
    /// Idle and runs to carry it with: Yasuo's with the sword out (his plain idle and run have it sheathed).
    var carry: (idle: [String], run: [String], fast: [String])? {
        self == .sword ? (["idle_out"], ["run_out_loop"], ["run_out_loop"]) : nil
    }
}

/// A weapon in the library: kept in its own frame (handle end at the origin, blade along +Y, flat side facing ±Z),
/// with its texture.
struct LibraryWeapon: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var origin: String
    var style: WeaponStyle          // suggested
    var length: Float
    /// Set for the weapon a style's moves come from (put in the hand exactly as that skin holds it).
    var reference: WeaponStyle?
    var vertexCount: Int
}

struct WeaponGeometry {
    var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], uvs: [SIMD2<Float>] = []
    var indices: [UInt32] = []
}

/// A weapon frame found from its shape: long axis from the handle (the narrower end) to the tip.
struct WeaponFrame {
    var handle: SIMD3<Float>
    var axes: (long: SIMD3<Float>, wide: SIMD3<Float>, thin: SIMD3<Float>)
    var length: Float

    init?(_ points: [SIMD3<Float>]) {
        guard points.count >= 3 else { return nil }
        let (c, a, _) = ThrownWeapon.shape(points)
        var long = a[0], wide = a[1]
        let s = points.map { simd_dot($0 - c, long) }
        guard let lo = s.min(), let hi = s.max(), hi - lo > 1e-4 else { return nil }
        let l = hi - lo
        // The handle is the rounder end (a grip or a shaft); blades and spear heads are flat.
        let thin = simd_cross(long, wide)
        func flatness(_ near: (Float) -> Bool) -> Float {
            let pts = zip(points, s).filter { near($0.1) }.map(\.0)
            guard pts.count > 2 else { return 1 }
            let mw = pts.map { simd_dot($0 - c, wide) }, mt = pts.map { simd_dot($0 - c, thin) }
            let aw = mw.reduce(0, +) / Float(mw.count), at = mt.reduce(0, +) / Float(mt.count)
            let sw = mw.map { abs($0 - aw) }.reduce(0, +), st = mt.map { abs($0 - at) }.reduce(0, +)
            return sw / max(st, 1e-6)
        }
        if flatness({ $0 > hi - 0.25 * l }) < flatness({ $0 < lo + 0.25 * l }) { long = -long; wide = -wide }
        let ends = points.map { simd_dot($0 - c, long) }
        handle = c + ends.min()! * long
        axes = (long, wide, simd_cross(long, wide))
        length = l
    }

    /// A point of the weapon's own frame (x: thin side, y: along, z: wide side) placed in this frame.
    func place(_ p: SIMD3<Float>) -> SIMD3<Float> { handle + p.y * axes.long + p.z * axes.wide + p.x * axes.thin }
    func turn(_ n: SIMD3<Float>) -> SIMD3<Float> { n.y * axes.long + n.z * axes.wide + n.x * axes.thin }
    func local(_ p: SIMD3<Float>) -> SIMD3<Float> {
        let d = p - handle
        return SIMD3(simd_dot(d, axes.thin), simd_dot(d, axes.long), simd_dot(d, axes.wide))
    }
    func localNormal(_ n: SIMD3<Float>) -> SIMD3<Float> { SIMD3(simd_dot(n, axes.thin), simd_dot(n, axes.long), simd_dot(n, axes.wide)) }
}

/// Weapons collected from every skin and model ported or imported, kept between sessions
/// (~/Library/Application Support/SkinLab/Weapons).
@MainActor
final class WeaponLibrary: ObservableObject {
    @Published private(set) var weapons: [LibraryWeapon] = []
    let dir: URL
    let referencesDir: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SkinLab")
        dir = base.appendingPathComponent("Weapons")
        referencesDir = base.appendingPathComponent("References")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: referencesDir, withIntermediateDirectories: true)
        reload()
    }

    func reload() {
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        weapons = ids.compactMap { id in
            (try? Data(contentsOf: dir.appendingPathComponent(id).appendingPathComponent("info.json")))
                .flatMap { try? JSONDecoder().decode(LibraryWeapon.self, from: $0) }
        }.sorted { ($0.reference != nil ? 0 : 1, $0.name) < ($1.reference != nil ? 0 : 1, $1.name) }
    }

    // MARK: Reference skins (the moves)

    /// The skin a style's moves come from: chosen by the user, else found in Downloads (copied here so it stays).
    func reference(_ style: WeaponStyle) -> URL? {
        let fm = FileManager.default
        if let p = UserDefaults.standard.string(forKey: "weaponReference.\(style.rawValue)"), fm.fileExists(atPath: p) { return URL(fileURLWithPath: p) }
        let kept = referencesDir.appendingPathComponent(style.defaultFile)
        if fm.fileExists(atPath: kept.path) { return kept }
        let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent(style.defaultFile)
        guard fm.fileExists(atPath: downloads.path), (try? fm.copyItem(at: downloads, to: kept)) != nil else { return nil }
        return kept
    }

    func setReference(_ style: WeaponStyle, _ url: URL) {
        let kept = referencesDir.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: kept)
        let path = (try? FileManager.default.copyItem(at: url, to: kept)) != nil ? kept.path : url.path
        UserDefaults.standard.set(path, forKey: "weaponReference.\(style.rawValue)")
        objectWillChange.send()
    }

    // MARK: Storage

    func geometry(_ w: LibraryWeapon) -> WeaponGeometry? {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent(w.id).appendingPathComponent("mesh.bin")), d.count >= 8 else { return nil }
        return d.withUnsafeBytes { raw -> WeaponGeometry? in
            let nv = Int(raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self)), ni = Int(raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
            guard d.count == 8 + nv * 32 + ni * 4 else { return nil }
            var g = WeaponGeometry()
            var o = 8
            func f() -> Float { defer { o += 4 }; return raw.loadUnaligned(fromByteOffset: o, as: Float.self) }
            for _ in 0 ..< nv {
                g.positions.append(SIMD3(f(), f(), f())); g.normals.append(SIMD3(f(), f(), f())); g.uvs.append(SIMD2(f(), f()))
            }
            for _ in 0 ..< ni { g.indices.append(raw.loadUnaligned(fromByteOffset: o, as: UInt32.self)); o += 4 }
            return g
        }
    }

    func texture(_ w: LibraryWeapon) -> RGBAImage? {
        let url = dir.appendingPathComponent(w.id).appendingPathComponent("texture.png")
        return ModelImport.image(url)
    }

    func remove(_ w: LibraryWeapon) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(w.id))
        reload()
    }

    /// Adds weapons found in a skin or model (the same weapon from the same place isn't added twice).
    @discardableResult
    func add(_ found: [Found], origin: String, reference: WeaponStyle? = nil) -> [LibraryWeapon] {
        var added: [LibraryWeapon] = []
        for f in found {
            let id = String(format: "%016llx", fnv64("\(origin)|\(f.name)|\(f.geometry.positions.count)|\(f.geometry.indices.count)"))
            let folder = dir.appendingPathComponent(id)
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent("info.json").path) {
                if reference != nil, var w = weapons.first(where: { $0.id == id }), w.reference != reference {
                    w.reference = reference
                    try? JSONEncoder().encode(w).write(to: folder.appendingPathComponent("info.json"))
                }
                continue
            }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var d = Data()
            func u32(_ v: UInt32) { withUnsafeBytes(of: v) { d.append(contentsOf: $0) } }
            func f32(_ v: Float) { withUnsafeBytes(of: v) { d.append(contentsOf: $0) } }
            let g = f.geometry
            u32(UInt32(g.positions.count)); u32(UInt32(g.indices.count))
            for i in g.positions.indices {
                f32(g.positions[i].x); f32(g.positions[i].y); f32(g.positions[i].z)
                f32(g.normals[i].x); f32(g.normals[i].y); f32(g.normals[i].z)
                f32(g.uvs[i].x); f32(g.uvs[i].y)
            }
            for i in g.indices { u32(i) }
            try? d.write(to: folder.appendingPathComponent("mesh.bin"))
            if let img = f.texture?.cgImage, let dest = CGImageDestinationCreateWithURL(folder.appendingPathComponent("texture.png") as CFURL,
                                                                                         UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, img, nil)
                CGImageDestinationFinalize(dest)
            }
            let length = g.positions.map(\.y).max() ?? 0
            let w = LibraryWeapon(id: id, name: f.name, origin: origin, style: reference ?? f.style, length: length, reference: reference,
                                  vertexCount: g.positions.count)
            try? JSONEncoder().encode(w).write(to: folder.appendingPathComponent("info.json"))
            added.append(w)
        }
        reload()
        return added
    }

    private func fnv64(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return h
    }

    // MARK: Finding weapons

    struct Found {
        var name: String
        var geometry: WeaponGeometry
        var texture: RGBAImage?
        var style: WeaponStyle
    }

    nonisolated static let cjkWeapons = ["武器", "剣", "剑", "刀", "槍", "枪", "矛", "弓", "斧", "镰", "鎌", "杖"]
    nonisolated static let spearWords = ["spear", "lance", "halberd", "glaive", "pike", "polearm", "naginata", "staff", "trident", "scythe",
                                         "槍", "枪", "矛", "杖", "镰", "鎌"]

    /// A part's name says it's a weapon.
    nonisolated static func looksLikeWeapon(_ name: String) -> Bool {
        WeaponSwap.isWeapon(name) || cjkWeapons.contains { name.contains($0) }
    }

    /// The weapons of a skin or model: its weapon parts, or (`wholeModel`) all of it as one weapon (a model of just a sword).
    nonisolated static func find(in skin: SkinData, only: [String]? = nil, wholeModel: Bool = false, modelName: String = "") -> [Found] {
        let mesh = skin.mesh
        let parts = wholeModel ? mesh.parts : mesh.parts.filter { only?.contains($0.name) ?? looksLikeWeapon($0.name) }
        // Parts of one weapon drawn with the same texture are kept together; a whole model is one weapon.
        var groups: [(name: String, parts: [SkinnedMesh.Part])] = []
        for p in parts {
            if wholeModel, !groups.isEmpty { groups[0].parts.append(p) } else { groups.append((wholeModel ? modelName : p.name, [p])) }
        }
        let height = mesh.positions.map(\.y).max() ?? 200
        return groups.compactMap { name, parts in
            var g = WeaponGeometry()
            var map: [Int: UInt32] = [:]
            var counts: [UInt64: Int] = [:]
            for p in parts {
                for k in p.startIndex ..< min(mesh.indices.count, p.startIndex + p.indexCount) {
                    let v = Int(mesh.indices[k])
                    if map[v] == nil {
                        map[v] = UInt32(g.positions.count)
                        g.positions.append(mesh.positions[v]); g.normals.append(mesh.normals[v]); g.uvs.append(mesh.uvs[v])
                    }
                    g.indices.append(map[v]!)
                }
                if let t = skin.partTexture[p.name] { counts[t, default: 0] += p.indexCount }
            }
            guard g.indices.count >= 3, let frame = WeaponFrame(g.positions) else { return nil }
            g.positions = g.positions.map(frame.local)
            g.normals = g.normals.map(frame.localNormal)
            let tex = counts.max { $0.value < $1.value }.flatMap { skin.textures[$0.key]?.image }
            let lower = name.lowercased()
            let style: WeaponStyle = spearWords.contains { lower.contains($0) } || (!wholeModel && frame.length > 0.7 * height) ? .spear : .sword
            return Found(name: name, geometry: g, texture: tex, style: style)
        }
    }

    /// A model with no body (no arms or legs found): it's a weapon on its own.
    nonisolated static func hasNoBody(_ skin: SkinData) -> Bool {
        guard let sk = skin.skeleton else { return true }
        let roles = Porter.roles(sk).compactMap { $0?.role }
        return !roles.contains(.hand) && !roles.contains(.thigh) && !roles.contains(.foot)
    }
}
