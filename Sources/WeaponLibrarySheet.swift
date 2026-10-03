import SwiftUI
import SceneKit
import UniformTypeIdentifiers

extension WeaponLibrary.Found: @unchecked Sendable {}

extension WeaponLibrary {
    /// Puts the weapons of the moves' skins (Zaahen's spear, the Ayaka skin's katana) in the library once.
    func seedReferences(championsDir: URL) async {
        for style in WeaponStyle.allCases where !weapons.contains(where: { $0.reference == style }) {
            guard let url = reference(style) else { continue }
            let found = await Task.detached { () -> (String, [Found])? in
                guard let info = try? FantomeInfo.inspect(url, championsDir: championsDir) else { return nil }
                let src = PortSource(modWad: info.modWad, champion: info.champion, skin: info.skins.first ?? 0, label: info.name)
                guard let files = try? src.open(championsDir: championsDir),
                      let skin = try? SkinData.load(files, champion: src.champion, num: src.skin) else { return nil }
                var f = WeaponLibrary.find(in: skin, only: [style.part])
                for i in f.indices { f[i].name = style == .spear ? "\(info.champion)'s spear" : "Ayaka's katana"; f[i].style = style }
                return (info.name, f)
            }.value
            if let (origin, f) = found { add(f, origin: origin, reference: style) }
        }
    }

    /// Weapons in a .fantome skin or a 3D model file.
    nonisolated static func weapons(in url: URL, championsDir: URL) throws -> [Found] {
        if url.pathExtension.lowercased() == "fantome" {
            let info = try FantomeInfo.inspect(url, championsDir: championsDir)
            let src = PortSource(modWad: info.modWad, champion: info.champion, skin: info.skins.first ?? 0, label: info.name)
            return find(in: try SkinData.load(try src.open(championsDir: championsDir), champion: src.champion, num: src.skin))
        }
        let model = try ModelImport.loadAny(url)
        return hasNoBody(model) ? find(in: model, wholeModel: true, modelName: url.deletingPathExtension().lastPathComponent) : find(in: model)
    }
}

@MainActor
final class WeaponPickModel: ObservableObject {
    @Published var selected: String?
    @Published var style: WeaponStyle = .spear
    @Published var message = ""
    @Published var loading = false
}

/// Weapons collected from skins and models: pick one to put in her hand, and whether Q swings it like a spear or a sword.
struct WeaponLibrarySheet: View {
    @ObservedObject var studio: Studio
    @ObservedObject var library: WeaponLibrary
    @StateObject private var pick = WeaponPickModel()

    init(studio: Studio) {
        self.studio = studio
        library = studio.weaponLibrary
    }

    var current: LibraryWeapon? { library.weapons.first { $0.id == pick.selected } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Weapons").font(.headline)
            Text("Every skin or model you port or import that has a weapon adds it here. Pick one to put in her hand for good.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)], spacing: 10) {
                    ForEach(library.weapons) { w in
                        card(w)
                            .onTapGesture { pick.selected = w.id; pick.style = w.reference ?? w.style }
                    }
                }
                .padding(2)
            }
            .frame(minHeight: 260)
            if library.weapons.isEmpty {
                Text(pick.loading ? "Looking for weapons…" : "No weapons yet: port a skin or import a model with one, or add one from a file.")
                    .foregroundStyle(.secondary)
            }
            Divider()
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Q swings it like a").font(.subheadline)
                    Picker("", selection: $pick.style) {
                        ForEach(WeaponStyle.allCases) { s in Text(s.title).tag(s) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                    Text(pick.style == .spear ? "Zaahen's Q1 and Q2, carried in idle and run like Zaahen carries his spear."
                                         : "The Ayaka skin's Q (the katana slashes), carried like she holds it.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: 260, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(WeaponStyle.allCases) { s in
                        HStack(spacing: 6) {
                            Text("\(s.title) moves:").font(.caption)
                            Text(library.reference(s)?.lastPathComponent ?? "not found").font(.caption)
                                .foregroundStyle(library.reference(s) == nil ? .red : .secondary).lineLimit(1).truncationMode(.middle)
                            Button("Change…") { chooseReference(s) }.controlSize(.small)
                        }
                    }
                }
            }
            if !pick.message.isEmpty { Text(pick.message).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            HStack {
                Button("Add from File…") { addFromFile() }
                    .help("A .fantome skin, or a .pmx / .blend / .gltf / .glb model (a model of just a weapon works too)")
                Button("Remove") { if let w = current { library.remove(w); pick.selected = nil } }
                    .disabled(current == nil || current?.reference != nil)
                if pick.loading { ProgressView().controlSize(.small) }
                Spacer()
                Button("Close") { studio.showWeaponLibrary = false }.keyboardShortcut(.cancelAction)
                Button("Put in Her Hand") {
                    guard let w = current else { return }
                    studio.showWeaponLibrary = false
                    studio.equip(w, style: pick.style)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(current == nil || library.reference(pick.style) == nil || studio.mesh == nil || studio.busy)
            }
        }
        .padding(20)
        .frame(width: 760, height: 620)
        .task {
            pick.selected = studio.equippedWeapon?.id
            if let s = studio.equippedWeapon?.style { pick.style = s }
            pick.loading = true
            await library.seedReferences(championsDir: studio.championsDir)
            pick.loading = false
            if pick.selected == nil { pick.selected = library.weapons.first?.id; pick.style = library.weapons.first.map { $0.reference ?? $0.style } ?? .spear }
        }
    }

    func card(_ w: LibraryWeapon) -> some View {
        let isSelected = w.id == pick.selected
        return VStack(alignment: .leading, spacing: 3) {
            WeaponPreview(library: library, weapon: w)
                .frame(height: 150)
                .background(Color.black.opacity(0.25))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            HStack(spacing: 4) {
                Text(w.name).font(.callout.weight(.medium)).lineLimit(1)
                if studio.equippedWeapon?.id == w.id { Image(systemName: "hand.raised.fill").font(.caption).foregroundStyle(.tint) }
            }
            Text(w.origin).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Text(w.reference.map { "\($0.title) moves come from it" } ?? "Looks like a \(w.style.title.lowercased())")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(isSelected ? Color.accentColor.opacity(0.25) : Color.gray.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2))
        .contentShape(Rectangle())
    }

    func chooseReference(_ s: WeaponStyle) {
        let p = NSOpenPanel()
        p.allowedContentTypes = [UTType(filenameExtension: "fantome") ?? .zip]
        p.message = "Choose the skin whose \(s.title.lowercased()) moves Q uses (\(s.defaultFile))"
        guard p.runModal() == .OK, let url = p.url else { return }
        library.setReference(s, url)
        Task { await library.seedReferences(championsDir: studio.championsDir) }
    }

    func addFromFile() {
        let p = NSOpenPanel()
        p.allowedContentTypes = ["fantome", "pmx", "blend", "gltf", "glb"].compactMap { UTType(filenameExtension: $0) }
        p.message = "Choose a skin or model with a weapon"
        guard p.runModal() == .OK, let url = p.url else { return }
        pick.loading = true
        pick.message = "Looking for weapons in \(url.lastPathComponent)…"
        let dir = studio.championsDir
        Task {
            do {
                let found = try await Task.detached { try WeaponLibrary.weapons(in: url, championsDir: dir) }.value
                let added = library.add(found, origin: url.deletingPathExtension().lastPathComponent)
                pick.message = found.isEmpty ? "No weapon found in \(url.lastPathComponent)"
                    : added.isEmpty ? "Its weapons are already here" : "Added \(added.map(\.name).joined(separator: ", "))"
                if let first = added.first { pick.selected = first.id; pick.style = first.style }
            } catch {
                pick.message = error.localizedDescription
            }
            pick.loading = false
        }
    }
}

/// A turning 3D view of a library weapon.
struct WeaponPreview: NSViewRepresentable {
    let library: WeaponLibrary
    let weapon: LibraryWeapon

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X
        view.scene = scene()
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {}

    func scene() -> SCNScene {
        let scene = SCNScene()
        guard let g = library.geometry(weapon), !g.positions.isEmpty else { return scene }
        let sources = [SCNGeometrySource(vertices: g.positions.map { SCNVector3($0.x, $0.y, $0.z) }),
                       SCNGeometrySource(normals: g.normals.map { SCNVector3($0.x, $0.y, $0.z) }),
                       SCNGeometrySource(textureCoordinates: g.uvs.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) })]
        let element = SCNGeometryElement(indices: g.indices, primitiveType: .triangles)
        let geometry = SCNGeometry(sources: sources, elements: [element])
        let material = SCNMaterial()
        material.diffuse.contents = library.texture(weapon)?.cgImage ?? NSColor.lightGray
        material.isDoubleSided = true
        material.lightingModel = .lambert
        geometry.materials = [material]
        let node = SCNNode(geometry: geometry)
        // Lying diagonally, centered, turning slowly.
        let length = max(weapon.length, 1)
        node.position = SCNVector3(0, -length / 2, 0)
        let holder = SCNNode()
        holder.addChildNode(node)
        holder.eulerAngles = SCNVector3(0, 0, -CGFloat.pi / 4)
        let spinner = SCNNode()
        spinner.addChildNode(holder)
        spinner.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 8)))
        scene.rootNode.addChildNode(spinner)
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.zFar = Double(length) * 10
        camera.position = SCNVector3(0, 0, CGFloat(length) * 0.8)
        scene.rootNode.addChildNode(camera)
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 500
        scene.rootNode.addChildNode(ambient)
        return scene
    }
}
