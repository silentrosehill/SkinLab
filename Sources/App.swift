import SwiftUI
import AppKit
import SceneKit
import UniformTypeIdentifiers
import simd

@main
struct SkinLabApp: App {
    /// SKINLAB_MODELCHECK=model.pmx|.blend|.gltf|.glb loads a model, prints what came in and quits (runs before any window).
    init() {
        let env = ProcessInfo.processInfo.environment
        if let path = env["SKINLAB_MODELCHECK"] {          // loads a .pmx / .blend and prints what came in
            do {
                let u = URL(fileURLWithPath: path)
                let m = try ModelImport.loadAny(u)
                let lo = m.mesh.positions.reduce(SIMD3<Float>(repeating: .greatestFiniteMagnitude)) { simd_min($0, $1) }
                let hi = m.mesh.positions.reduce(SIMD3<Float>(repeating: -.greatestFiniteMagnitude)) { simd_max($0, $1) }
                print("vertices \(m.mesh.positions.count) triangles \(m.mesh.indices.count / 3) bounds \(lo) \(hi)")
                for p in m.mesh.parts { print("part \(p.name): \(p.indexCount / 3) triangles, texture \(m.partTexture[p.name].map { m.textures[$0].map { "\($0.image.width)x\($0.image.height)" } ?? "?" } ?? "none")") }
                let sk = m.skeleton!
                let roles = Porter.roles(sk)
                for (i, j) in sk.joints.enumerated() where roles[i] != nil || env["SKINLAB_ALLBONES"] != nil {
                    print("bone \(j.name) parent \(j.parent >= 0 ? sk.joints[j.parent].name : "-") at \(j.bind.columns.3) role \(roles[i].map { "\($0)" } ?? "-")")
                }
                print("bones \(sk.joints.count) influences \(sk.influences.count)")
                if let out = env["SKINLAB_MODELRENDER"] {
                    DebugDump.renderRest(m, to: URL(fileURLWithPath: out + "_front.png"))
                    DebugDump.renderRest(m, to: URL(fileURLWithPath: out + "_side.png"), side: true)
                }
            } catch { print("error: \(error)") }
            exit(0)
        }
    }

    var body: some Scene {
        WindowGroup("SkinLab") {
            ContentView()
                .frame(minWidth: 1000, minHeight: 620)
        }
    }
}

/// Lets buttons reach the 3D view (for the preview picture saved in the mod).
final class ViewerHandle {
    weak var view: SCNView?
    func snapshot() -> NSImage? { view?.snapshot() }
}

struct ContentView: View {
    @StateObject private var studio = Studio()
    private let viewer = ViewerHandle()

    var body: some View {
        NavigationSplitView(columnVisibility: $studio.sidebar) {
            List(selection: Binding(get: { studio.champion }, set: { if let c = $0 { studio.open(champion: c) } })) {
                ForEach(studio.champions.filter { studio.search.isEmpty || $0.localizedCaseInsensitiveContains(studio.search) }, id: \.self) {
                    Text($0).tag($0)
                }
            }
            .searchable(text: $studio.search, placement: .sidebar, prompt: "Champion")
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            VStack(spacing: 0) {
                HSplitView {
                    VStack(spacing: 0) {
                    ZStack {
                        if studio.mesh != nil {
                            ModelView(studio: studio, handle: viewer)
                        } else {
                            Text(studio.champion == nil ? "Pick a champion" : (studio.busy ? "Loading…" : "No model"))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        if studio.busy { ProgressView().controlSize(.large) }
                    }
                    if studio.mesh != nil && studio.paintMode {
                        Divider()
                        PaintBar(studio: studio)
                    }
                    if studio.mesh != nil && !studio.clipList.isEmpty {
                        Divider()
                        AnimationBar(studio: studio)
                    }
                    }
                    .frame(minWidth: 380)
                    TexturePanel(studio: studio)
                        .frame(minWidth: 300, idealWidth: 340, maxWidth: 460)
                }
                Divider()
                HStack {
                    Text(studio.status).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
            }
        }
        .toolbar {
            ToolbarItem {
                Picker("Skin", selection: Binding(get: { studio.skin ?? -1 }, set: { if $0 >= 0 { studio.open(skin: $0) } })) {
                    if studio.skins.isEmpty { Text("No skin").tag(-1) }
                    ForEach(studio.skins) { Text($0.name).tag($0.id) }
                }
                .frame(width: 240)
                .disabled(studio.skins.isEmpty || studio.busy)
            }
            ToolbarItem {
                if studio.portedFrom != nil {
                    Button("Undo Port") { studio.undoPort() }
                        .help("Go back to the champion's own model")
                } else {
                    Button("Port from…") { studio.showPortSheet = true }
                        .help("Put another champion's skin, or a custom skin, on this one")
                        .disabled(studio.mesh == nil || studio.busy)
                }
            }
            ToolbarItem {
                Toggle(isOn: $studio.paintMode) { Label("Paint", systemImage: "paintbrush") }
                    .help("Paint on the model to fix or touch up its textures")
                    .disabled(studio.mesh == nil)
            }
            ToolbarItem {
                Button("Colors from Picture…") { studio.chooseStylePicture() }
                    .help("Recolor the skin with the colors of a picture")
                    .disabled(studio.mesh == nil || studio.busy)
            }
            ToolbarItem {
                Button(studio.vfxPicks.isEmpty ? "Spell Effects…" : "Spell Effects (\(studio.vfxPicks.count))…") { studio.showVfxSheet = true }
                    .help("Use another skin's effects for some spells, e.g. Winterblessed's E")
                    .disabled(studio.mesh == nil || studio.busy)
            }
            ToolbarItem {
                Button("Weapons…") { studio.showWeaponLibrary = true }
                    .help("Pick a weapon for her hand from every skin and model you've ported, with spear or sword moves on Q")
                    .disabled(studio.mesh == nil || studio.busy)
            }
            ToolbarItem {
                Button("Weapon from Skin…") { studio.showAddWeaponSheet = true }
                    .help("Put another skin's weapon (e.g. Zaahen's spear) in her hand for good")
                    .disabled(studio.mesh == nil || studio.busy)
            }
            ToolbarItem {
                if studio.portedFrom != nil || studio.extraWeapon != nil {
                    Button("Weapon on Spells…") { studio.showWeaponSheet = true }
                        .help("Draw a weapon of the ported skin on Q and W, with its own slashes")
                        .disabled(studio.busy)
                }
            }
            ToolbarItem {
                Menu("Parts") {
                    ForEach(studio.mesh?.parts.map(\.name) ?? [], id: \.self) { name in
                        Toggle(name, isOn: Binding(get: { !studio.hiddenParts.contains(name) },
                                                   set: { on in
                                                       if on { studio.hiddenParts.remove(name) } else { studio.hiddenParts.insert(name) }
                                                   }))
                    }
                }
                .help(studio.portedFrom == nil ? "Show or hide model parts in the preview"
                      : "Untick parts to leave them out of the saved skin")
                .disabled(studio.mesh == nil)
            }
            ToolbarItem {
                Button("Game Folder…") { chooseGameFolder() }
                    .help(studio.gamePath)
            }
            ToolbarItem {
                Button { studio.exportFantome(preview: viewer.snapshot()) } label: {
                    Label("Save .fantome…", systemImage: "square.and.arrow.down")
                }
                .help("Save your changes as a custom skin for Zushi")
                .disabled(studio.mesh == nil)
            }
        }
        .sheet(isPresented: $studio.showPortSheet) { PortSheet(studio: studio) }
        .sheet(isPresented: $studio.showWeaponSheet) { WeaponSheet(studio: studio) }
        .sheet(isPresented: $studio.showVfxSheet) { VfxSheet(studio: studio) }
        .sheet(isPresented: $studio.showAddWeaponSheet) { AddWeaponSheet(studio: studio) }
        .sheet(isPresented: $studio.showWeaponLibrary) { WeaponLibrarySheet(studio: studio) }
        .onAppear(perform: runSnapshotTestIfAsked)
    }

    private func chooseGameFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = true
        p.message = "Choose League of Legends.app or its Game folder"
        guard p.runModal() == .OK, let url = p.url else { return }
        for candidate in [url.appendingPathComponent("Contents/LoL/Game"), url, url.appendingPathComponent("Game")]
        where FileManager.default.fileExists(atPath: candidate.appendingPathComponent("DATA/FINAL/Champions").path) {
            studio.gamePath = candidate.path
            return
        }
        studio.status = "That folder doesn't contain League's game files"
    }

    /// SKINLAB_TEST=Champion:skin:out.png[:out.fantome] loads a skin, saves a picture of the 3D view and quits (for testing).
    /// With a .fantome path, every texture is hue-shifted first and the mod is saved there.
    private func runSnapshotTestIfAsked() {
        if let sheetPath = ProcessInfo.processInfo.environment["SKINLAB_SHEET"], let out = ProcessInfo.processInfo.environment["SKINLAB_OUT"] {
            do {
                guard let img = NSImage(contentsOf: URL(fileURLWithPath: sheetPath))?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw FormatError("can't open") }
                let views = try Sheet.read(img)
                for v in views {
                    print("\(v.label) angle \(v.angle): \(v.width)x\(v.height) top \(v.top) bottom \(v.bottom) axis \(v.axis)")
                    var px = [UInt8](repeating: 0, count: v.width * v.height * 4)
                    let ctx = CGContext(data: &px, width: v.width, height: v.height, bitsPerComponent: 8, bytesPerRow: v.width * 4,
                                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                    ctx.draw(v.image, in: CGRect(x: 0, y: 0, width: v.width, height: v.height))
                    for i in 0 ..< v.width * v.height where !v.mask[i] { px[i * 4] /= 4; px[i * 4 + 1] /= 4; px[i * 4 + 2] = 255 }
                    let outImg = ctx.makeImage()!
                    let rep = NSBitmapImageRep(cgImage: outImg)
                    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/view_\(Int(abs(v.angle))).png"))
                }
            } catch { print("error: \(error)") }
            NSApp.terminate(nil)
        }
        let env = ProcessInfo.processInfo.environment
        if let spec = env["SKINLAB_RESTCHECK"] {          // Champion:skin — rest pose from local transforms vs bind matrices
            let p = spec.split(separator: ":").map(String.init)
            if let wad = try? Wad(url: studio.championsDir.appendingPathComponent("\(p[0]).wad.client")),
               let data = try? SkinData.load(wad, champion: p[0], num: Int(p[1]) ?? 0), let sk = data.skeleton, let sd = data.skeletonData {
                let g = sk.globals(sk.restPoses(sd))
                var worstPos: Float = 0, worstRot: Float = 0, worstName = ""
                for (j, joint) in sk.joints.enumerated() {
                    let dp = simd_distance(Retarget.position(g[j]), joint.position)
                    let a = Retarget.rotation(g[j]), b = Retarget.rotation(joint.bind)
                    let ang = 2 * acos(min(abs(simd_dot(a.vector, b.vector)), 1)) * 180 / .pi
                    if ang > worstRot { worstRot = ang; worstName = joint.name }
                    worstPos = max(worstPos, dp)
                }
                print("rest-from-locals vs bind: worst position diff \(worstPos), worst rotation diff \(worstRot)° (\(worstName))")
            }
            NSApp.terminate(nil)
        }
        if let wadPath = env["SKINLAB_ENCODETEST"] {
            if let wad = try? Wad(url: URL(fileURLWithPath: wadPath)) {
                var n = 0, worstAngle: Float = 0, worstMove: Float = 0, failed = 0
                for h in wad.entries.keys {
                    guard let d = try? wad.read(h), d.starts(with: Data("r3d2".utf8)), !d.starts(with: Data("r3d2Mesh".utf8)) else { continue }
                    guard let a = try? AnimClip.decode(d), let b = try? AnimClip.decode(a.encoded()) else { failed += 1; continue }
                    n += 1
                    for (joint, poses) in a.tracks {
                        guard let other = b.tracks[joint], other.count == poses.count else { failed += 1; break }
                        for (p, q) in zip(poses, other) {
                            let dot = abs(simd_dot(p.rotation.vector, q.rotation.vector))
                            worstAngle = max(worstAngle, 2 * acos(min(dot, 1)) * 180 / .pi)
                            worstMove = max(worstMove, simd_distance(p.translation, q.translation))
                        }
                    }
                }
                print("re-encoded \(n) animations, \(failed) failed; worst rotation error \(worstAngle)°, worst position error \(worstMove)")
            }
            NSApp.terminate(nil)
        }
        if let wadPath = env["SKINLAB_ANMHEAD"] {
            if let wad = try? Wad(url: URL(fileURLWithPath: wadPath)) {
                var shown = 0
                for h in wad.entries.keys.sorted() {
                    guard shown < 4, let d = try? wad.read(h), d.starts(with: Data("r3d2anmd".utf8)) else { continue }
                    let b = [UInt8](d)
                    func u(_ o: Int) -> UInt32 { UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24 }
                    let fields = stride(from: 8, to: 64, by: 4).map { o -> String in
                        o == 36 ? String(format: "%g", Float(bitPattern: u(o))) : String(Int32(bitPattern: u(o)))
                    }
                    print(String(format: "%016llx", h), "size", d.count, fields.joined(separator: " "))
                    shown += 1
                }
            }
            NSApp.terminate(nil)
        }
        if let spec = env["SKINLAB_GRAPHTYPES"] {      // <wad>|<bin path or hash>
            let p = spec.split(separator: "|").map(String.init)
            if let wad = try? Wad(url: URL(fileURLWithPath: p[0])) {
                let h = p[1].count == 16 ? UInt64(p[1], radix: 16) ?? pathHash(p[1]) : pathHash(p[1])
                if let d = try? wad.read(h), let f = try? BinFile.parse(d),
                   let g = f.objects.first(where: { $0.cls == fnv("AnimationGraphData") }), case let .map(k, v, entries)? = g["mClipDataMap"] {
                    print(String(format: "clip map key 0x%02x value 0x%02x, %d clips", k, v, entries.count))
                    for (key, value) in entries {
                        guard case let .embed(kind, _, _) = value, case let .map(ek, ev, evs)? = value["mEventDataMap"] else { continue }
                        print(String(format: "clip %@ embed kind 0x%02x events map key 0x%02x value 0x%02x (%d)", DebugDump.describe(key), kind, ek, ev, evs.count))
                        for (_, e) in evs {
                            if case let .embed(ekind, cls, fields) = e, cls == fnv("SubmeshVisibilityEventData") {
                                print(String(format: "  submesh event kind 0x%02x", ekind), fields.map { f in
                                    DebugDump.name(f.name) + String(format: ":0x%02x", f.value.typeByte) + {
                                        if case let .list(lk, le, _) = f.value { return String(format: "(list 0x%02x of 0x%02x)", lk, le) }; return "" }() })
                            }
                        }
                        break
                    }
                    let withSubmesh = entries.first { _, v in
                        if case let .map(_, _, evs)? = v["mEventDataMap"] { return evs.contains { if case let .embed(_, c, _) = $0.1 { return c == fnv("SubmeshVisibilityEventData") }; return false } }
                        return false
                    }
                    if let (_, v) = withSubmesh, case let .map(_, _, evs)? = v["mEventDataMap"] {
                        for (_, e) in evs { if case let .embed(ekind, cls, fields) = e, cls == fnv("SubmeshVisibilityEventData") {
                            print(String(format: "submesh event kind 0x%02x", ekind), fields.map { f in
                                DebugDump.name(f.name) + String(format: ":0x%02x", f.value.typeByte) + {
                                    if case let .list(lk, le, _) = f.value { return String(format: "(list 0x%02x of 0x%02x)", lk, le) }; return "" }() })
                        } }
                    }
                }
            }
            NSApp.terminate(nil)
        }
        if let wadPath = env["SKINLAB_WADLS"] {
            DebugDump.listWad(URL(fileURLWithPath: wadPath), showBins: true)
            NSApp.terminate(nil)
        }
        if let spec = env["SKINLAB_BINDUMP"] {
            // <wad file>|<game path or 16-hex hash>
            let p = spec.split(separator: "|").map(String.init)
            if p.count == 2, let wad = try? Wad(url: URL(fileURLWithPath: p[0])) {
                let h = p[1].count == 16 ? UInt64(p[1], radix: 16) ?? pathHash(p[1]) : pathHash(p[1])
                if let d = try? wad.read(h) { DebugDump.dumpBin(d, max: Int(env["SKINLAB_DEPTH"] ?? "") ?? 6) } else { print("not found") }
            }
            NSApp.terminate(nil)
        }
        if let dir = ProcessInfo.processInfo.environment["SKINLAB_INSPECT"] {
            let src = FolderSource(URL(fileURLWithPath: dir))
            let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            var anms = Set<UInt64>()
            for f in files where f.hasSuffix(".anm") { if let h = UInt64(f.prefix(16), radix: 16) { anms.insert(h) } }
            for f in files where f.hasSuffix(".skl") {
                if let d = src.data(UInt64(f.prefix(16), radix: 16)!), let sk = try? Skeleton.parse(d) {
                    for n in ["Root", "Pelvis", "L_Hip", "L_KneeUpper", "L_Foot", "Head"] {
                        if let i = sk.index(named: n) { print(n, sk.joints[i].position, "local", sk.joints[i].local) }
                    }
                }
            }
            for f in files where f.hasSuffix(".bin") {
                guard let d = src.data(UInt64(f.prefix(16), radix: 16)!), let bin = try? BinFile.parse(d) else { print(f, "doesn't parse"); continue }
                var refs = 0, ours = 0, strings: [String] = []
                for o in bin.objects { for fl in o.fields { fl.value.walk { v in
                    if case let .string(s) = v, s.lowercased().hasSuffix(".anm") { refs += 1; if anms.contains(pathHash(s)) { ours += 1 } else { strings.append(s) } }
                    if case let .file(h) = v, anms.contains(h) { refs += 1; ours += 1 }
                } } }
                print(f, "objects", bin.objects.count, "anm refs", refs, "pointing at our files", ours, strings.prefix(3))
            }
            let root = Skeleton.elf("Root"), knee = Skeleton.elf("L_KneeUpper"), foot = Skeleton.elf("L_Foot")
            for f in files.filter({ $0.hasSuffix(".anm") }).prefix(3) {
                let d = src.data(UInt64(f.prefix(16), radix: 16)!)!
                print(f, "root", AnimEdit.sampleTranslations(d, joint: root).first ?? .zero, "knee", AnimEdit.sampleTranslations(d, joint: knee).first ?? .zero,
                      "foot", AnimEdit.sampleTranslations(d, joint: foot).first ?? .zero)
            }
            NSApp.terminate(nil)
        }
        if let champ = ProcessInfo.processInfo.environment["SKINLAB_ANM"] {
            if let wad = try? Wad(url: studio.championsDir.appendingPathComponent("\(champ).wad.client")) {
                var kinds: [String: Int] = [:]
                var sizes: [String: Int] = [:]
                for h in wad.entries.keys {
                    guard let d = try? wad.read(h), d.count >= 8 else { continue }
                    let magic = String(decoding: d.prefix(8), as: UTF8.self)
                    if magic.hasPrefix("r3d2") { kinds[magic, default: 0] += 1; sizes[magic, default: 0] += d.count }
                }
                for (k, n) in kinds { print("\(k): \(n) files, \(sizes[k]! / 1024) KB") }
                var same = 0, differ = 0, failed = 0, shown = 0
                let root = Skeleton.elf("Root"), foot = Skeleton.elf("L_Foot")
                for h in wad.entries.keys {
                    guard let d = try? wad.read(h), d.count > 12, String(decoding: d.prefix(4), as: UTF8.self) == "r3d2",
                          String(decoding: d.prefix(8), as: UTF8.self) != "r3d2Mesh" else { continue }
                    do {
                        let e = try AnimEdit.edit(d, joints: [root, foot]) { _, v in v }
                        if e == d { same += 1 } else { differ += 1 }
                        let a = AnimEdit.allTranslations(d, joints: [root, foot]), b = AnimEdit.allTranslations(e, joints: [root, foot])
                        let worst = zip(a, b).map { simd_length($0 - $1) }.max() ?? 0
                        if a.count != b.count || worst > 0.05 { print("  values changed: \(a.count) vs \(b.count), worst \(worst)") }
                        // a real change: lower Root by 20 and check it took
                        let low = try AnimEdit.edit(d, joints: [root]) { _, v in v - SIMD3(0, 20, 0) }
                        let ra = AnimEdit.allTranslations(d, joints: [root]), rb = AnimEdit.allTranslations(low, joints: [root])
                        if let x = ra.first, let y = rb.first, abs((x.y - y.y) - 20) > 0.05 { print("  lowering failed: \(x.y) -> \(y.y)") }
                        let rs = d.subdata(in: 12 ..< 16).withUnsafeBytes { $0.load(as: UInt32.self) }
                        if shown < 6 {
                            shown += 1
                            print(String(decoding: d.prefix(8), as: UTF8.self), "size", d.count, "resSize", rs,
                                  "root", AnimEdit.sampleTranslations(d, joint: root), "foot", AnimEdit.sampleTranslations(d, joint: foot).first ?? .zero)
                        }
                    } catch { failed += 1; print("fail: \(error)") }
                }
                print("identity edit: \(same) identical, \(differ) re-encoded, \(failed) failed")
            }
            NSApp.terminate(nil)
        }
        if let champs = ProcessInfo.processInfo.environment["SKINLAB_ROUNDTRIP"] {
            for c in champs.split(separator: ",").map(String.init) { Studio.roundTrip(gamePath: studio.gamePath, champion: c) }
            NSApp.terminate(nil)
        }
        if let spec = ProcessInfo.processInfo.environment["SKINLAB_DUMP"] {
            let p = spec.split(separator: ":").map(String.init)
            Studio.dump(gamePath: studio.gamePath, champion: p[0], skin: Int(p[1]) ?? 0)
            NSApp.terminate(nil)
        }
        guard let spec = ProcessInfo.processInfo.environment["SKINLAB_TEST"] else { return }
        let p = spec.split(separator: ":").map(String.init)
        guard p.count >= 3 else { return }
        studio.open(champion: p[0])
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { studio.open(skin: Int(p[1]) ?? 0) }
        // SKINLAB_PORT=Champion:skin[:head,hands,lowerLegs,feet] ports that skin on first
        var wait = 6.0
        if let port = ProcessInfo.processInfo.environment["SKINLAB_PORT"]?.split(separator: ":").map(String.init), port.count >= 2 {
            let keep = Set((port.count > 2 ? port[2] : "").split(separator: ",").compactMap { k in
                KeepRegion.allCases.first { "\($0)" == k }
            })
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                let ext = URL(fileURLWithPath: port[0]).pathExtension.lowercased()
                if ["pmx", "blend", "gltf", "glb"].contains(ext) {
                    studio.port(model: URL(fileURLWithPath: port[0]), keep: keep, naturalLegs: ProcessInfo.processInfo.environment["SKINLAB_LEGS"] != nil)
                } else if ["png", "jpg", "jpeg", "webp"].contains(ext) {
                    studio.port(sheet: URL(fileURLWithPath: port[0]), keep: keep)
                } else if port[0].hasSuffix(".fantome"), let info = try? FantomeInfo.inspect(URL(fileURLWithPath: port[0]), championsDir: studio.championsDir) {
                    print("mod \(info.name): \(info.champion), skins \(info.skins)")
                    studio.port(from: PortSource(modWad: info.modWad, champion: info.champion, skin: info.skins.first ?? 0, label: info.name), keep: keep,
                                naturalLegs: ProcessInfo.processInfo.environment["SKINLAB_LEGS"] != nil,
                                swapWeapon: ProcessInfo.processInfo.environment["SKINLAB_NOSWAP"] == nil)
                } else {
                    studio.port(from: PortSource(modWad: nil, champion: port[0], skin: Int(port[1]) ?? 0, label: port[0]), keep: keep,
                                naturalLegs: ProcessInfo.processInfo.environment["SKINLAB_LEGS"] != nil,
                                swapWeapon: ProcessInfo.processInfo.environment["SKINLAB_NOSWAP"] == nil)
                }
            }
            wait = 14
        }
        if let spec = ProcessInfo.processInfo.environment["SKINLAB_CLIPFILES"] {     // a.fantome or Champion:skin — idle/run clips and files
            let dir = studio.championsDir
            Task.detached {
                let src: PortSource
                if spec.hasSuffix(".fantome"), let info = try? FantomeInfo.inspect(URL(fileURLWithPath: spec), championsDir: dir) {
                    src = PortSource(modWad: info.modWad, champion: info.champion, skin: info.skins.first ?? 0, label: info.name)
                } else {
                    let q = spec.split(separator: ":").map(String.init)
                    src = PortSource(modWad: nil, champion: q[0], skin: Int(q.count > 1 ? q[1] : "0") ?? 0, label: q[0])
                }
                guard let files = try? src.open(championsDir: dir), let skin = try? SkinData.load(files, champion: src.champion, num: src.skin) else { print("can't open"); return }
                for c in skin.clips(files) where ProcessInfo.processInfo.environment["SKINLAB_ALLCLIPS"] != nil || ["idle", "run", "walk", "spell1"].contains(where: { c.label.lowercased().contains($0) }) {
                    print("clip \(c.label): file \(c.file.map { String(format: "%016llx", $0) } ?? "-") frames \(c.animation(files)?.frameCount ?? -1) inMod \(c.file.map { src.modWad != nil && (try? files.data($0)) != nil } ?? false)")
                }
                print("parts:", skin.mesh.parts.map(\.name))
            }
            wait += 6
        }
        if ProcessInfo.processInfo.environment["SKINLAB_LISTCLIPS"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                Task {
                    let list = await studio.sourceClips().sorted { $0.label.lowercased() < $1.label.lowercased() }
                    print("source clips:", list.map(\.label).joined(separator: ", "))
                    let spells = list.filter { c in
                        let l = c.label.lowercased()
                        return l.hasPrefix("spell1") && !["dash", "wind", "run", "idle", "to_idle", "_in", "_out"].contains { l.contains($0) }
                    }
                    print("default Q1:", spells.first?.label ?? "-", " default Q2:", spells.dropFirst().first?.label ?? "-")
                }
            }
            wait += 4
        }
        if let spec = ProcessInfo.processInfo.environment["SKINLAB_ADDWEAPON"] {     // /path/skin.fantome:part — weapon from another skin
            let q = spec.split(separator: ":").map(String.init)
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                if let info = try? FantomeInfo.inspect(URL(fileURLWithPath: q[0]), championsDir: studio.championsDir) {
                    studio.addWeapon(from: PortSource(modWad: info.modWad, champion: info.champion, skin: info.skins.first ?? 0, label: info.name),
                                     part: q[1], carry: true)
                }
            }
            wait += 25
        }
        if let spec = ProcessInfo.processInfo.environment["SKINLAB_EQUIP"] {     // name:spear|sword — a library weapon in her hand
            let q = spec.split(separator: ":").map(String.init)
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                Task {
                    await studio.weaponLibrary.seedReferences(championsDir: studio.championsDir)
                    print("library:", studio.weaponLibrary.weapons.map { "\($0.name) [\($0.origin)] \($0.style) \(Int($0.length))" })
                    guard let w = studio.weaponLibrary.weapons.first(where: { $0.name.lowercased().contains(q[0].lowercased()) }) else { print("no weapon \(q[0])"); return }
                    studio.equip(w, style: WeaponStyle(rawValue: q.count > 1 ? q[1] : "spear") ?? .spear)
                }
            }
            wait += 45
            if let pose = ProcessInfo.processInfo.environment["SKINLAB_EQUIPPOSE"] {     // Clip:fraction after equipping
                let pq = pose.split(separator: ":").map(String.init)
                DispatchQueue.main.asyncAfter(deadline: .now() + wait - 1) {
                    studio.previewOverridePose(clip: pq[0], at: Float(pq.count > 1 ? pq[1] : "0.5") ?? 0.5)
                }
                wait += 1
            }
        }
        if ProcessInfo.processInfo.environment["SKINLAB_SHOWLIBRARY"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { studio.showWeaponLibrary = true }
        }
        if let spec = ProcessInfo.processInfo.environment["SKINLAB_WEAPON"] {
            let q = spec.split(separator: ":").map(String.init)
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                Task {    // part:Q1:Q2:W, "-" keeps the champion's own, "auto" (W) finds a left-to-right slash
                    let clips = await studio.sourceClips()
                    func pick(_ i: Int) -> ClipInfo? { q.count > i ? clips.first { $0.label.lowercased() == q[i].lowercased() } : nil }
                    var w = pick(3)
                    var wFrom: PortSource?
                    if q.count > 3, q[3] == "auto", let s = await studio.suggestedSlash(part: q[0], among: clips) {
                        w = clips.first { $0.name == s }
                        print("suggested W:", w?.label ?? "-")
                    }
                    if q.count > 3, q[3].hasPrefix("skin="),     // W of another skin: skin=/path/to/mod.fantome
                       let info = try? FantomeInfo.inspect(URL(fileURLWithPath: String(q[3].dropFirst(5))), championsDir: studio.championsDir) {
                        wFrom = PortSource(modWad: info.modWad, champion: info.champion, skin: info.skins.first ?? 0, label: info.name)
                    }
                    studio.setUpSpellWeapon(part: q[0] == "held" ? Studio.heldPart : q[0], q1: pick(1), q2: pick(2), w: w, wFrom: wFrom)
                }
            }
            wait += q.count > 3 ? 25 : 8
            if let pose = ProcessInfo.processInfo.environment["SKINLAB_OVERPOSE"] {
                let pq = pose.split(separator: ":").map(String.init)
                DispatchQueue.main.asyncAfter(deadline: .now() + wait - 1) {
                    print(studio.status)
                    studio.previewOverridePose(clip: pq[0], at: Float(pq.count > 1 ? pq[1] : "0.5") ?? 0.5)
                }
                wait += 1
            }
        }
        if let spec = ProcessInfo.processInfo.environment["SKINLAB_VFX"] {     // E:31,Q:21 — effects from other skins
            DispatchQueue.main.asyncAfter(deadline: .now() + wait - 1) {
                for pair in spec.split(separator: ",") {
                    let kv = pair.split(separator: ":")
                    if kv.count == 2, let n = Int(kv[1]) { studio.vfxPicks[String(kv[0])] = n }
                }
                print("effects from:", studio.vfxPicks)
            }
        }
        if let out = ProcessInfo.processInfo.environment["SKINLAB_PAINTTEST"] {     // paints a stroke across the view, saves the texture
            DispatchQueue.main.asyncAfter(deadline: .now() + wait - 1) {
                guard let v = viewer.view as? PaintSCNView, let win = v.window else { print("no view"); return }
                studio.paintMode = true
                studio.paintColor = CGColor(srgbRed: 1, green: 0.1, blue: 0.1, alpha: 1)
                studio.brushStrength = 1
                studio.brushSize = 12
                let b = v.bounds
                func ev(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) -> NSEvent {
                    let pw = v.convert(CGPoint(x: x, y: y), to: nil)
                    return NSEvent.mouseEvent(with: type, location: pw, modifierFlags: [], timestamp: 0, windowNumber: win.windowNumber,
                                              context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                }
                let y = b.midY + b.height * 0.1
                v.mouseDown(with: ev(.leftMouseDown, b.midX - b.width * 0.15, y))
                for i in 0 ... 30 { v.mouseDragged(with: ev(.leftMouseDragged, b.midX - b.width * 0.15 + b.width * 0.3 * CGFloat(i) / 30, y)) }
                v.mouseUp(with: ev(.leftMouseUp, b.midX + b.width * 0.15, y))
                for (i, slot) in studio.textures.enumerated() where slot.paint != nil {
                    if let img = slot.edited, let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: "\(out)_\(i).png"))
                        print("painted texture \(i) \(slot.parts) saved, changed: \(slot.isChanged)")
                    }
                }
            }
            wait += 2
        }
        if ProcessInfo.processInfo.environment["SKINLAB_SHOWSHEET"] != nil {     // opens the weapon sheet (for screenshots)
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { studio.showWeaponSheet = true }
            wait += 25
        }
        if ProcessInfo.processInfo.environment["SKINLAB_LOOP"] != nil { studio.loopPlayback = true }
        if let spec = ProcessInfo.processInfo.environment["SKINLAB_PLAY"] {     // Title:seconds — play a quick-bar animation
            let q = spec.split(separator: ":").map(String.init)
            DispatchQueue.main.asyncAfter(deadline: .now() + wait - 1) {
                if let c = studio.quickClips.first(where: { $0.title == q[0] })?.clip ?? studio.clipList.first(where: { $0.label == q[0] }) {
                    studio.play(c)
                    print("playing", c.label, studio.status)
                } else { print("no clip", q[0], studio.quickClips.map(\.title)) }
            }
            wait += Double(q.count > 1 ? q[1] : "0.5") ?? 0.5
        }
        if let spec = ProcessInfo.processInfo.environment["SKINLAB_POSE"] {     // ClipName:fraction
            let q = spec.split(separator: ":").map(String.init)
            DispatchQueue.main.asyncAfter(deadline: .now() + wait - 1) { studio.previewPose(clip: q[0], at: Float(q.count > 1 ? q[1] : "0.5") ?? 0.5) }
            wait += 2
        }
        if let pic = ProcessInfo.processInfo.environment["SKINLAB_STYLE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + wait - 2) { studio.useStylePicture(URL(fileURLWithPath: pic)) }
            wait += 4
        }
        let styled = ProcessInfo.processInfo.environment["SKINLAB_STYLE"] != nil
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
            if p.count == 4 && studio.portedFrom == nil && !styled {
                for slot in studio.textures { slot.adjust.hue = 120; studio.changed(slot) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + wait + 1) {
            if p.count == 4 { studio.exportFantome(preview: viewer.snapshot(), to: URL(fileURLWithPath: p[3])) }
            if let img = viewer.snapshot(), let tiff = img.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: p[2]))
            }
            print(studio.status)
            NSApp.terminate(nil)
        }
    }
}

// MARK: - 3D view

struct ModelView: NSViewRepresentable {
    @ObservedObject var studio: Studio
    let handle: ViewerHandle

    /// League models are mirrored compared to SceneKit: everything shown goes through this flip.
    static let mirror = simd_float4x4(diagonal: SIMD4(-1, 1, 1, 1))

    final class Coordinator {
        var meshKey = ""
        var container: SCNNode?
        var model: SCNNode?
        var joints: [SCNNode] = []
        var skeleton: Skeleton?
        var rest: [JointPose] = []
        var parts: [String] = []
        var timer: Timer?
        weak var studio: Studio?
        var showingRest = true

        /// One step of animation playback: pose the bones, apply the clip's show/hide events.
        @MainActor func tick() {
            guard let studio, let model, let sk = skeleton, joints.count == sk.joints.count else { return }
            guard let pb = studio.playback else {
                if !showingRest { setPose(rest); applyVisibility(studio, events: [], frame: 0); showingRest = true }
                return
            }
            showingRest = false
            let clip = pb.clip
            var t = Float(Date().timeIntervalSince(pb.started)) * clip.fps
            let last = Float(max(clip.frameCount - 1, 0))
            if pb.loop, last > 0 { t = t.truncatingRemainder(dividingBy: last + 1) } else { t = min(t, last) }
            let f0 = Int(t), f1 = min(f0 + 1, Int(last)), a = t - Float(f0)
            let poses: [JointPose] = sk.joints.indices.map { j in
                guard let track = clip.tracks[sk.joints[j].nameHash], !track.isEmpty else { return rest[j] }
                let p0 = track[min(f0, track.count - 1)], p1 = track[min(f1, track.count - 1)]
                return JointPose(rotation: simd_slerp(p0.rotation, p1.rotation, a),
                                 translation: simd_mix(p0.translation, p1.translation, SIMD3(repeating: a)),
                                 scale: simd_mix(p0.scale, p1.scale, SIMD3(repeating: a)))
            }
            setPose(poses)
            applyVisibility(studio, events: pb.events, frame: t)
            if !pb.loop && t >= last && Date().timeIntervalSince(pb.started) > Double(clip.duration) + 0.6 { studio.stopPlayback() }
            _ = model
        }

        func setPose(_ poses: [JointPose]) {
            for (j, node) in joints.enumerated() where j < poses.count {
                node.simdTransform = ModelView.mirror * poses[j].matrix * ModelView.mirror
            }
        }

        @MainActor func applyVisibility(_ studio: Studio, events: [Studio.PartEvent], frame: Float) {
            guard let geometry = model?.geometry else { return }
            var visible = Dictionary(parts.map { ($0, !studio.hiddenParts.contains($0)) }, uniquingKeysWith: { a, _ in a })
            for e in events where e.frame <= frame {
                for p in e.show { visible[p] = true }
                for p in e.hide { visible[p] = false }
            }
            for (i, part) in parts.enumerated() where i < geometry.materials.count {
                let on = visible[part] ?? true
                geometry.materials[i].colorBufferWriteMask = on ? .all : []
                geometry.materials[i].writesToDepthBuffer = on
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SCNView {
        let v = PaintSCNView()
        v.studio = studio
        v.scene = SCNScene()
        v.allowsCameraControl = true
        v.autoenablesDefaultLighting = true
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 450
        v.scene?.rootNode.addChildNode(ambient)
        v.backgroundColor = NSColor(white: 0.16, alpha: 1)
        v.antialiasingMode = .multisampling4X
        v.rendersContinuously = true
        handle.view = v
        let c = context.coordinator
        c.studio = studio
        c.timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak c] _ in
            MainActor.assumeIsolated { c?.tick() }
        }
        return v
    }

    func updateNSView(_ v: SCNView, context: Context) {
        v.window?.invalidateCursorRects(for: v)
        guard let mesh = studio.mesh else { return }
        let c = context.coordinator
        c.studio = studio
        let key = "\(studio.champion ?? "")-\(studio.skin ?? -1)-\(mesh.indices.count)-\(mesh.positions.count)-\(studio.portedFrom ?? "")-\(studio.sizeFactor)-\(studio.meshVersion)"
        if key != c.meshKey {
            c.meshKey = key
            c.container?.removeFromParentNode()
            let container = SCNNode()
            container.scale = SCNVector3(studio.sizeFactor, studio.sizeFactor, studio.sizeFactor)
            let model = SCNNode(geometry: Self.geometry(mesh))
            container.addChildNode(model)
            c.joints = []
            c.skeleton = nil
            if let (sk, rest) = studio.animSkeleton, rest.count == sk.joints.count {
                // Bones as nodes, the model skinned to them: playing an animation just moves the bones.
                let nodes = sk.joints.map { _ in SCNNode() }
                for (j, joint) in sk.joints.enumerated() {
                    nodes[j].simdTransform = Self.mirror * rest[j].matrix * Self.mirror
                    if joint.parent >= 0 && joint.parent < nodes.count { nodes[joint.parent].addChildNode(nodes[j]) } else { container.addChildNode(nodes[j]) }
                }
                let restGlobals = sk.globals(rest)
                let bones = sk.influences.map { nodes[min(max($0, 0), nodes.count - 1)] }
                let inverseBinds = sk.influences.map { j -> NSValue in
                    let m = Self.mirror * restGlobals[min(max(j, 0), restGlobals.count - 1)].inverse * Self.mirror
                    return NSValue(scnMatrix4: SCNMatrix4(m))
                }
                var w = [Float](), b = [UInt16]()
                w.reserveCapacity(mesh.positions.count * 4)
                for i in mesh.positions.indices {
                    for k in 0 ..< 4 {
                        w.append(mesh.weights[i][k])
                        b.append(UInt16(min(Int(mesh.boneIndices[i][k]), max(bones.count - 1, 0))))
                    }
                }
                let weights = SCNGeometrySource(data: w.withUnsafeBufferPointer { Data(buffer: $0) }, semantic: .boneWeights,
                                                vectorCount: mesh.positions.count, usesFloatComponents: true, componentsPerVector: 4,
                                                bytesPerComponent: 4, dataOffset: 0, dataStride: 16)
                let indices = SCNGeometrySource(data: b.withUnsafeBufferPointer { Data(buffer: $0) }, semantic: .boneIndices,
                                                vectorCount: mesh.positions.count, usesFloatComponents: false, componentsPerVector: 4,
                                                bytesPerComponent: 2, dataOffset: 0, dataStride: 8)
                if !bones.isEmpty, let geometry = model.geometry {
                    let skinner = SCNSkinner(baseGeometry: geometry, bones: bones, boneInverseBindTransforms: inverseBinds,
                                             boneWeights: weights, boneIndices: indices)
                    skinner.skeleton = container
                    model.skinner = skinner
                    c.joints = nodes
                    c.skeleton = sk
                    c.rest = rest
                }
            }
            v.scene?.rootNode.addChildNode(container)
            c.container = container
            c.model = model
            c.parts = mesh.parts.map(\.name)
            c.showingRest = true
            frame(v, on: container, mesh: mesh, hidden: studio.hiddenParts)
        }
        guard let geometry = c.model?.geometry else { return }
        let slots = Dictionary(studio.textures.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (i, part) in mesh.parts.enumerated() where i < geometry.materials.count {
            let m = geometry.materials[i]
            if studio.playback == nil {
                let hidden = studio.hiddenParts.contains(part.name)
                m.colorBufferWriteMask = hidden ? [] : .all
                m.writesToDepthBuffer = !hidden
            }
            if let h = studio.partTexture[part.name], let img = slots[h]?.edited {
                m.diffuse.contents = img
            } else {
                m.diffuse.contents = NSColor.gray
            }
        }
    }

    static func dismantleNSView(_ v: SCNView, coordinator: Coordinator) {
        coordinator.timer?.invalidate()
    }

    private static func geometry(_ mesh: SkinnedMesh) -> SCNGeometry {
        // League is left-handed: mirror X (and flip the triangle winding to match).
        let vertices = SCNGeometrySource(vertices: mesh.positions.map { SCNVector3(-$0.x, $0.y, $0.z) })
        let normals = SCNGeometrySource(normals: mesh.normals.map { SCNVector3(-$0.x, $0.y, $0.z) })
        let uvData = mesh.uvs.withUnsafeBufferPointer { Data(buffer: $0) }
        let uvs = SCNGeometrySource(data: uvData, semantic: .texcoord, vectorCount: mesh.uvs.count,
                                    usesFloatComponents: true, componentsPerVector: 2, bytesPerComponent: 4,
                                    dataOffset: 0, dataStride: 8)
        let elements = mesh.parts.map { part -> SCNGeometryElement in
            let end = min(mesh.indices.count, part.startIndex + part.indexCount)
            var idx = part.startIndex < end ? Array(mesh.indices[part.startIndex ..< end]) : []
            for t in stride(from: 0, to: idx.count - 2, by: 3) { idx.swapAt(t + 1, t + 2) }
            return SCNGeometryElement(indices: idx, primitiveType: .triangles)
        }
        let g = SCNGeometry(sources: [vertices, normals, uvs], elements: elements)
        g.materials = mesh.parts.map { _ in
            let m = SCNMaterial()
            m.isDoubleSided = true
            m.lightingModel = .lambert
            m.blendMode = .replace          // texture alpha is often a mask, not see-through
            m.diffuse.wrapS = .repeat       // the mirrored half of a model reuses the texture past its edge
            m.diffuse.wrapT = .repeat
            return m
        }
        return g
    }

    /// Points the camera at the visible parts, ignoring the odd far-off vertex.
    private func frame(_ v: SCNView, on node: SCNNode, mesh: SkinnedMesh, hidden: Set<String>) {
        var pts: [SIMD3<Float>] = []
        for part in mesh.parts where !hidden.contains(part.name) {
            let idx = mesh.indices[part.startIndex ..< min(mesh.indices.count, part.startIndex + part.indexCount)]
            for i in stride(from: idx.startIndex, to: idx.endIndex, by: max(1, idx.count / 3000)) {
                let p = mesh.positions[Int(idx[i])]
                pts.append(SIMD3(-p.x, p.y, p.z))
            }
        }
        func pct(_ values: [Float], _ q: Float) -> Float {
            let s = values.sorted()
            return s.isEmpty ? 0 : s[min(s.count - 1, Int(Float(s.count - 1) * q))]
        }
        var lo = SCNVector3(-50, 0, -50), hi = SCNVector3(50, 200, 50)
        if pts.count > 10 {
            let xs = pts.map(\.x), ys = pts.map(\.y), zs = pts.map(\.z)
            lo = SCNVector3(pct(xs, 0.01), pct(ys, 0.005), pct(zs, 0.01))
            hi = SCNVector3(pct(xs, 0.99), pct(ys, 0.995), pct(zs, 0.99))
        }
        let k = node.scale.y
        let center = SCNVector3((lo.x + hi.x) / 2 * k, (lo.y + hi.y) / 2 * k, (lo.z + hi.z) / 2 * k)
        let size = max(hi.y - lo.y, hi.x - lo.x, 1) * k
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.zFar = Double(size) * 20
        camera.position = SCNVector3(center.x, center.y, center.z + size * 1.2)
        camera.look(at: center)
        v.scene?.rootNode.childNodes.filter { $0.camera != nil }.forEach { $0.removeFromParentNode() }
        v.scene?.rootNode.addChildNode(camera)
        v.pointOfView = camera
    }
}

/// The 3D view: turns the camera, or paints on the model in Paint mode (hold ⌥ to turn the camera while painting).
final class PaintSCNView: SCNView {
    weak var studio: Studio?
    private var painting = false
    private var radiusUV: Float = 0.01

    private var paintActive: Bool { studio?.paintMode ?? false }

    override func resetCursorRects() {
        if paintActive { addCursorRect(bounds, cursor: .crosshair) } else { super.resetCursorRects() }
    }

    override func mouseDown(with e: NSEvent) {
        guard paintActive, !e.modifierFlags.contains(.option) else { super.mouseDown(with: e); return }
        painting = true
        allowsCameraControl = false
        dab(e, begin: true)
    }

    override func mouseDragged(with e: NSEvent) {
        if painting { dab(e, begin: false) } else { super.mouseDragged(with: e) }
    }

    override func mouseUp(with e: NSEvent) {
        if painting { painting = false; allowsCameraControl = true } else { super.mouseUp(with: e) }
    }

    /// Paints where the pointer is on the model: the part and texture spot under it, the brush sized on screen
    /// (from how much texture the touched triangle covers per unit of its size).
    private func dab(_ e: NSEvent, begin: Bool) {
        guard let studio, let mesh = studio.mesh else { return }
        let p = convert(e.locationInWindow, from: nil)
        let options: [SCNHitTestOption: Any] = [.searchMode: SCNHitTestSearchMode.closest.rawValue, .ignoreHiddenNodes: true]
        guard let h = hitTest(p, options: options).first(where: { hit in
            hit.node.geometry != nil && hit.geometryIndex < mesh.parts.count && !studio.hiddenParts.contains(mesh.parts[hit.geometryIndex].name)
        }) else { return }
        let part = mesh.parts[h.geometryIndex]
        let t = h.textureCoordinates(withMappingChannel: 0)
        let uv = SIMD2(Float(t.x), Float(t.y))
        // Texture units per model unit on this triangle.
        let first = part.startIndex + h.faceIndex * 3
        if first + 2 < mesh.indices.count {
            let v = (0 ..< 3).map { Int(mesh.indices[first + $0]) }
            let world = simd_distance(mesh.positions[v[1]], mesh.positions[v[0]]) + simd_distance(mesh.positions[v[2]], mesh.positions[v[0]])
            let tex = simd_distance(mesh.uvs[v[1]], mesh.uvs[v[0]]) + simd_distance(mesh.uvs[v[2]], mesh.uvs[v[0]])
            // The brush's size on screen, as a distance on the model at the touched point.
            let projected = projectPoint(h.worldCoordinates)
            let edge = unprojectPoint(SCNVector3(projected.x + CGFloat(studio.brushSize), projected.y, projected.z))
            let a = h.node.convertPosition(h.worldCoordinates, from: nil), b = h.node.convertPosition(edge, from: nil)
            let modelRadius = Float(sqrt(pow(a.x - b.x, 2) + pow(a.y - b.y, 2) + pow(a.z - b.z, 2)))
            if world > 0.0001, tex > 0 { radiusUV = min(max(modelRadius * tex / world, 0.0005), 0.08) }
        }
        studio.paint(part: part.name, uv: uv, radius: radiusUV, beginStroke: begin)
    }
}

/// Brush settings, shown under the 3D view in Paint mode.
struct PaintBar: View {
    @ObservedObject var studio: Studio

    var body: some View {
        HStack(spacing: 10) {
            Picker("", selection: $studio.paintTool) {
                ForEach(PaintLayer.Tool.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 290)
            ColorPicker("", selection: $studio.paintColor, supportsOpacity: false).labelsHidden()
            Text("Size").font(.caption)
            Slider(value: $studio.brushSize, in: 3 ... 90).frame(width: 90)
            Text("Strength").font(.caption)
            Slider(value: $studio.brushStrength, in: 0.05 ... 1).frame(width: 80)
            Button("Undo") { studio.undoPaint() }.keyboardShortcut("z").disabled(!studio.canUndoPaint)
            Menu("…") { Button("Remove All Paint") { studio.clearPaint() } }.fixedSize()
            Spacer(minLength: 0)
        }
        .controlSize(.small)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .help("Drag on the model to paint. Hold ⌥ (Option) to turn the camera.")
    }
}

/// Buttons under the 3D view that play the skin's animations.
struct AnimationBar: View {
    @ObservedObject var studio: Studio

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(studio.quickClips, id: \.title) { item in
                        Button(item.title) { studio.play(item.clip) }
                            .help(item.clip.label)
                            .fixedSize()
                    }
                }
            }
            Menu("All") {
                ForEach(studio.clipList.sorted { $0.label.lowercased() < $1.label.lowercased() }, id: \.name) { clip in
                    Button(clip.label) { studio.play(clip) }
                }
            }
            .fixedSize()
            .disabled(studio.clipList.isEmpty)
            Toggle("Loop", isOn: $studio.loopPlayback)
                .toggleStyle(.checkbox)
                .fixedSize()
            Button { studio.stopPlayback() } label: { Image(systemName: "stop.fill") }
                .disabled(studio.playback == nil)
                .help("Back to the rest pose")
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

// MARK: - Texture editing

struct TexturePanel: View {
    @ObservedObject var studio: Studio

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Skin name", text: $studio.modName)
                TextField("Author", text: $studio.modAuthor)
            }
            .padding(10)
            if let palette = studio.stylePalette {
                Divider()
                StyleBox(studio: studio, palette: palette)
            }
            Divider()
            if studio.textures.isEmpty {
                Text(studio.mesh == nil ? "" : "No editable textures found")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(studio.textures) { TextureCard(slot: $0, studio: studio, palette: studio.stylePalette) }
                    }
                    .padding(10)
                }
            }
        }
    }
}

struct StyleBox: View {
    @ObservedObject var studio: Studio
    let palette: Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                if let img = studio.stylePicture {
                    Image(decorative: img, scale: 1).resizable().scaledToFit().frame(width: 56, height: 56)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Colors from picture").font(.headline)
                    HStack(spacing: 3) {
                        ForEach(palette.rgb.indices, id: \.self) { i in
                            Swatch(rgb: palette.rgb[i]).help("\(Int(palette.weights[i] * 100))% of the picture")
                        }
                    }
                    if !studio.styleFoundSubject {
                        Text("No character found, so the whole picture was used").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Remove") { studio.clearStyle() }.controlSize(.small)
            }
            HStack {
                Text("Strength").frame(width: 74, alignment: .leading)
                Slider(value: Binding(get: { studio.styleStrength },
                                      set: { studio.styleStrength = $0; studio.restyle(remap: false) }), in: 0 ... 1.5)
            }
            .font(.callout)
            Toggle("Keep skin tones", isOn: Binding(get: { studio.keepSkin },
                                                    set: { studio.keepSkin = $0; studio.restyle(remap: true) }))
                .font(.callout)
        }
        .padding(10)
    }
}

struct Swatch: View {
    let rgb: SIMD3<Float>?
    var size: CGFloat = 18

    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(rgb.map { Color(red: Double($0.x), green: Double($0.y), blue: Double($0.z)) } ?? Color.clear)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.primary.opacity(0.3), lineWidth: 0.5))
            .overlay { if rgb == nil { Image(systemName: "nosign").font(.system(size: size * 0.55)).foregroundStyle(.secondary) } }
            .frame(width: size, height: size)
    }
}

struct TextureCard: View {
    @ObservedObject var slot: TextureSlot
    let studio: Studio
    var palette: Palette?

    private func slider(_ title: String, _ kp: WritableKeyPath<Adjust, Double>, _ range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title).frame(width: 74, alignment: .leading)
            Slider(value: Binding(get: { slot.adjust[keyPath: kp] },
                                  set: { slot.adjust[keyPath: kp] = $0; studio.changed(slot) }), in: range)
        }
        .font(.callout)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                if let img = slot.edited {
                    Image(decorative: img, scale: 1).resizable().interpolation(.medium)
                        .frame(width: 72, height: 72).border(Color.secondary.opacity(0.4))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(slot.parts.joined(separator: ", ")).font(.headline).lineLimit(2)
                    Text("\(slot.original.width)×\(slot.original.height) · .\(slot.fileExtension)")
                        .font(.caption).foregroundStyle(.secondary)
                    if slot.isChanged { Text("Changed").font(.caption).foregroundStyle(.orange) }
                }
            }
            if let palette {
                Toggle("Use picture colors", isOn: Binding(get: { slot.styleMapping != nil },
                                                          set: { studio.setStyle($0, for: slot) }))
                    .font(.callout)
                if let mapping = slot.styleMapping {
                    let tex = slot.palette.rgb
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 62), spacing: 6)], alignment: .leading, spacing: 4) {
                        ForEach(tex.indices, id: \.self) { i in
                            HStack(spacing: 2) {
                                Swatch(rgb: tex[i])
                                Image(systemName: "arrow.right").font(.system(size: 8)).foregroundStyle(.secondary)
                                Button { studio.cycle(i, of: slot) } label: {
                                    Swatch(rgb: i < mapping.count && mapping[i] >= 0 && mapping[i] < palette.colors.count ? palette.rgb[mapping[i]] : nil)
                                }
                                .buttonStyle(.plain)
                                .help("Click to pick another picture color (or keep the original)")
                            }
                        }
                    }
                }
            }
            slider("Hue", \.hue, -180 ... 180)
            slider("Saturation", \.saturation, 0 ... 2)
            slider("Brightness", \.brightness, -0.5 ... 0.5)
            slider("Contrast", \.contrast, 0.5 ... 1.5)
            HStack {
                Text("Tint").frame(width: 74, alignment: .leading)
                ColorPicker("", selection: Binding(get: { Color(nsColor: slot.adjust.tint) },
                                                   set: { slot.adjust.tint = NSColor($0); studio.changed(slot) }),
                            supportsOpacity: false)
                    .labelsHidden()
                Slider(value: Binding(get: { slot.adjust.tintAmount },
                                      set: { slot.adjust.tintAmount = $0; studio.changed(slot) }), in: 0 ... 1)
            }
            .font(.callout)
            HStack {
                Button("Replace…") { replace() }.help("Use your own image for this texture")
                Button("Export PNG…") { exportPNG() }.help("Save it, paint on it in any app, then use Replace…")
                Spacer()
                Button("Reset") { slot.reset(); studio.changed(slot) }.disabled(!slot.isChanged)
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    private func replace() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        guard p.runModal() == .OK, let url = p.url, let img = NSImage(contentsOf: url),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        slot.replacement = cg
        studio.changed(slot)
    }

    private func exportPNG() {
        let p = NSSavePanel()
        p.allowedContentTypes = [.png]
        p.nameFieldStringValue = "\(slot.parts.first ?? "texture").png"
        guard p.runModal() == .OK, let url = p.url, let img = slot.edited,
              let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }
}
