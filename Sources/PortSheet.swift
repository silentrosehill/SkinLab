import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
final class PortSheetModel: ObservableObject {
    enum From: Hashable { case game, file, sheet, model }
    @Published var modelFile: URL?
    @Published var from = From.game
    @Published var sheet: URL?
    @Published var champion = ""
    @Published var skins: [SkinChoice] = []
    @Published var skin = 0
    @Published var fantome: FantomeInfo?
    @Published var keep: Set<KeepRegion> = []
    @Published var naturalLegs = UserDefaults.standard.bool(forKey: "portNaturalLegs") {
        didSet { UserDefaults.standard.set(naturalLegs, forKey: "portNaturalLegs") }
    }
    @Published var keepHeight = UserDefaults.standard.object(forKey: "portKeepHeight") as? Bool ?? true {
        didSet { UserDefaults.standard.set(keepHeight, forKey: "portKeepHeight") }
    }
    @Published var swapWeapon = UserDefaults.standard.object(forKey: "portSwapWeapon") as? Bool ?? true {
        didSet { UserDefaults.standard.set(swapWeapon, forKey: "portSwapWeapon") }
    }
    @Published var message = ""
    @Published var loading = false

    func pick(champion name: String, studio: Studio) {
        champion = name
        skins = []
        loading = true
        Task {
            let list = await studio.skinList(for: name)
            guard self.champion == name else { return }
            self.skins = list
            self.skin = list.first?.id ?? 0
            self.loading = false
        }
    }

    func chooseFile(studio: Studio) {
        let p = NSOpenPanel()
        p.allowedContentTypes = [UTType(filenameExtension: "fantome") ?? .zip, .zip]
        p.message = "Choose a custom skin (.fantome or .zip)"
        guard p.runModal() == .OK, let url = p.url else { return }
        loading = true
        message = "Reading \(url.lastPathComponent)…"
        let dir = studio.championsDir
        Task {
            do {
                let info = try await Task.detached { try FantomeInfo.inspect(url, championsDir: dir) }.value
                let names = await studio.skinNames(for: info.champion)
                self.fantome = info
                self.skins = info.skins.map { SkinChoice(id: $0, name: names[$0] ?? ($0 == 0 ? "Base" : "Skin \($0)")) }
                self.skin = info.skins.first ?? 0
                self.message = info.skins.isEmpty ? "This mod doesn't seem to change any \(info.champion) skin" : ""
                if info.madeBySkinLab && info.champion == studio.champion {
                    self.message = "This skin was already made with SkinLab for \(info.champion): it's ready to import in Zushi as it is. "
                        + "Porting it again would fit it a second time. To change it, port the original skin instead."
                }
            } catch {
                self.fantome = nil
                self.message = error.localizedDescription
            }
            self.loading = false
        }
    }

    func chooseSheet() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        p.message = "Choose a character sheet with labelled Front, Side, 3/4 and Back views"
        guard p.runModal() == .OK, let url = p.url else { return }
        sheet = url
    }

    var ready: Bool { from == .sheet ? sheet != nil : from == .model ? modelFile != nil : source != nil }

    func chooseModel() {
        let p = NSOpenPanel()
        p.allowedContentTypes = ["pmx", "blend", "gltf", "glb"].compactMap { UTType(filenameExtension: $0) }
        p.message = "Choose a character model (.pmx with its textures in the same folder, a Blender .blend, or a glTF .gltf / .glb)"
        guard p.runModal() == .OK, let url = p.url else { return }
        modelFile = url
    }

    var source: PortSource? {
        if from == .sheet || from == .model { return nil }
        if from == .file {
            guard let f = fantome, !skins.isEmpty, !(f.madeBySkinLab && message.hasPrefix("This skin was already made")) else { return nil }
            return PortSource(modWad: f.modWad, champion: f.champion, skin: skin, label: f.name)
        }
        guard !champion.isEmpty, !skins.isEmpty else { return nil }
        let name = skins.first { $0.id == skin }?.name ?? "Skin \(skin)"
        return PortSource(modWad: nil, champion: champion, skin: skin, label: name == "Base" ? champion : name)
    }
}

struct PortSheet: View {
    @ObservedObject var studio: Studio
    @StateObject private var model = PortSheetModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Port a skin onto \(studio.champion ?? "") (\(studio.skinName))").font(.headline)
            Picker("", selection: $model.from) {
                Text("From the game").tag(PortSheetModel.From.game)
                Text("From a custom skin").tag(PortSheetModel.From.file)
                Text("From a 3D model").tag(PortSheetModel.From.model)
                // "From a character sheet" (Reconstruct.swift) is parked: the rebuilt shapes aren't good enough yet.
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if model.from == .sheet {
                HStack {
                    Button("Choose Picture…") { model.chooseSheet() }
                    if let url = model.sheet { Text(url.lastPathComponent).lineLimit(1) }
                }
                Text("A picture with labelled views (Front, 3/4 Front, Side, 3/4 Back, Back) of a character in a T-pose. "
                     + "The shape is rebuilt from the outlines, so expect a rough model.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if model.from == .model {
                HStack {
                    Button("Choose Model…") { model.chooseModel() }
                    if let url = model.modelFile { Text(url.lastPathComponent).lineLimit(1) }
                }
                Text("An MMD model (.pmx) with its textures, like the official Genshin Impact character models, a Blender file (.blend) or a glTF model (.gltf / .glb, from Sketchfab, VRoid…): "
                     + "what the file shows when opened is imported, hidden outfits and variants stay out. "
                     + "It's fitted to \(studio.champion ?? "the champion")'s skeleton and simplified if it has too many points for League.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.from == .file {
                HStack {
                    Button("Choose .fantome…") { model.chooseFile(studio: studio) }
                    if let f = model.fantome { Text("\(f.name) (\(f.champion))").lineLimit(1) }
                }
            } else {
                Picker("Champion", selection: Binding(get: { model.champion }, set: { model.pick(champion: $0, studio: studio) })) {
                    if model.champion.isEmpty { Text("Choose…").tag("") }
                    ForEach(studio.champions, id: \.self) { Text($0).tag($0) }
                }
            }
            if model.from != .sheet && model.from != .model {
                Picker("Skin", selection: $model.skin) {
                    ForEach(model.skins) { Text($0.name).tag($0.id) }
                }
                .disabled(model.skins.isEmpty)
            }

            Divider()
            Text("Keep \(studio.champion ?? "the champion")'s own:").font(.subheadline)
            HStack(spacing: 16) {
                ForEach(KeepRegion.allCases) { r in
                    Toggle(r.rawValue, isOn: Binding(get: { model.keep.contains(r) },
                                                     set: { if $0 { model.keep.insert(r) } else { model.keep.remove(r) } }))
                }
            }
            Text("Useful when bodies differ a lot, like Camille's blade legs.")
                .font(.caption).foregroundStyle(.secondary)

            Divider()
            Toggle(isOn: $model.naturalLegs) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Normal body proportions")
                    Text("Keeps the character's own leg length instead of stretching it to \(studio.champion ?? "the champion")'s. "
                         + "The skin gets its own shorter skeleton and adjusted animations.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle("Keep \(studio.champion ?? "the champion")'s usual height", isOn: $model.keepHeight)
                .disabled(!model.naturalLegs)
                .padding(.leading, 20)
                .help("Draws the skin bigger so it stands as tall as usual. Off: the character keeps its natural size and looks shorter.")

            Toggle(isOn: $model.swapWeapon) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Swap weapons")
                    Text("\(studio.champion ?? "The champion")'s weapon becomes the skin's weapon, held the way the skin holds it, "
                         + "and used in every animation like the old one (e.g. Gragas's barrel → Gwen's scissors).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if !model.message.isEmpty { Text(model.message).font(.callout).foregroundStyle(.secondary) }

            HStack {
                if model.loading { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { studio.showPortSheet = false }.keyboardShortcut(.cancelAction)
                Button("Port") {
                    studio.showPortSheet = false
                    if model.from == .model, let url = model.modelFile {
                        studio.port(model: url, keep: model.keep, naturalLegs: model.naturalLegs, keepHeight: model.keepHeight)
                    } else if model.from == .sheet, let url = model.sheet {
                        studio.port(sheet: url, keep: model.keep, naturalLegs: model.naturalLegs, keepHeight: model.keepHeight)
                    } else if let s = model.source {
                        studio.port(from: s, keep: model.keep, naturalLegs: model.naturalLegs, keepHeight: model.keepHeight, swapWeapon: model.swapWeapon)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.ready || model.loading)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
