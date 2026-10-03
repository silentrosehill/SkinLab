import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class WeaponSheetModel: ObservableObject {
    @Published var clips: [ClipInfo] = []
    @Published var part = ""
    // Clip names of the source skin's animations; 0 keeps the champion's own.
    @Published var q1: UInt32 = 0
    @Published var q2: UInt32 = 0
    @Published var w: UInt32 = 0
    @Published var loading = true
    @Published var findingSlash = false
    @Published var suggestedW: String?
    /// W from another skin of the champion (its own W), chosen with "Another skin's W…".
    @Published var wSkin: PortSource?
    @Published var wSkinProblem: String?
    static let otherSkin = UInt32.max

    func chooseOtherSkin(_ studio: Studio) {
        let p = NSOpenPanel()
        p.allowedContentTypes = [UTType(filenameExtension: "fantome") ?? .data, .zip]
        p.message = "Choose a \(studio.champion ?? "") custom skin (.fantome) whose W you want"
        guard p.runModal() == .OK, let url = p.url else {
            if wSkin == nil { w = 0 }
            return
        }
        wSkinProblem = nil
        do {
            let info = try FantomeInfo.inspect(url, championsDir: studio.championsDir)
            guard info.champion.lowercased() == (studio.champion ?? "").lowercased() else {
                wSkinProblem = "\(info.name) is for \(info.champion), not \(studio.champion ?? "this champion")"
                if wSkin == nil { w = 0 }
                return
            }
            wSkin = PortSource(modWad: info.modWad, champion: info.champion, skin: info.skins.first ?? 0, label: info.name)
            w = Self.otherSkin
        } catch {
            wSkinProblem = "Couldn't open it: \(error.localizedDescription)"
            if wSkin == nil { w = 0 }
        }
    }

    func load(_ studio: Studio) {
        let parts = studio.mesh?.parts.map(\.name) ?? []
        let weaponWords = ["katana", "sword", "blade", "weapon", "spear", "axe", "scythe", "staff", "gun"]
        part = studio.spellWeapon?.part ?? (studio.heldWeapons.isEmpty ? nil : Studio.heldPart)
            ?? parts.first { p in weaponWords.contains { p.lowercased().contains($0) } } ?? parts.first ?? ""
        Task {
            let list = await studio.sourceClips().sorted { $0.label.lowercased() < $1.label.lowercased() }
            self.clips = list
            if let current = studio.spellWeapon {
                self.q1 = current.picks.q1 ?? 0
                self.q2 = current.picks.q2 ?? 0
                self.w = current.picks.w ?? 0
                self.wSkin = current.wFrom
                self.loading = false
                return
            }
            // The source's Q attacks: "Spell1", "Spell1A", "Spell1B"… (not its dashes, wind or run variants).
            let spells = list.filter { c in
                let l = c.label.lowercased()
                return l.contains("spell1") && !["dash", "wind", "run", "walk", "idle", "to_idle", "_in", "_out"].contains { l.contains($0) }
            }.sorted { $0.label.lowercased() < $1.label.lowercased() }
            self.q1 = (spells.first ?? list.first)?.name ?? 0
            // Q2: another of its Q attacks that isn't the same animation as Q1.
            func same(_ a: ClipInfo, _ b: ClipInfo?) -> Bool { b != nil && (a.file ?? 0) == (b!.file ?? 0) && a.sequence == b!.sequence }
            self.q2 = spells.dropFirst().first { !same($0, spells.first) }?.name ?? spells.dropFirst().first?.name ?? self.q1
            self.loading = false
            // W: a slash from the left to the right, if the source has one.
            self.findingSlash = true
            let slash = await studio.suggestedSlash(part: self.part, among: list)
            self.findingSlash = false
            if let slash, let c = list.first(where: { $0.name == slash }) {
                self.suggestedW = c.label
                if self.w == 0 { self.w = slash }
            }
        }
    }
}

/// Draw a weapon for spells: on Q (shown with the first Q, kept while Q is up, put away after the second)
/// and on W (shown for W, its swing landing when W hits).
struct WeaponSheet: View {
    @ObservedObject var studio: Studio
    @StateObject private var model = WeaponSheetModel()

    private var champion: String { studio.champion ?? "the champion" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Weapon on Spells").font(.headline)
            Text("The weapon appears in the right hand for each spell you give an animation from \(studio.portedFrom ?? "the ported skin"). "
                 + "Q: drawn with the first Q, kept while Q is up, put away after the second. "
                 + "W: drawn for W and put away after it. The swing is held back so the blade passes in front of \(champion) "
                 + "right when W hits, like her own W. Or take the W of another \(champion) custom skin.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Weapon", selection: $model.part) {
                if !studio.heldWeapons.isEmpty { Text("Already in her hands (always shown)").tag(Studio.heldPart) }
                ForEach(studio.mesh?.parts.map(\.name) ?? [], id: \.self) { Text($0).tag($0) }
            }
            if model.loading {
                ProgressView().controlSize(.small)
            } else if model.clips.isEmpty {
                Text("This skin's animations couldn't be read.").foregroundStyle(.secondary)
            } else {
                picker("Q animation", $model.q1)
                picker("Q2 animation", $model.q2)
                Picker("W animation", selection: $model.w) {
                    Text("Keep \(champion)'s own").tag(UInt32(0))
                    Text(model.wSkin.map { "\($0.label)'s own W" } ?? "Another \(champion) skin's W…").tag(WeaponSheetModel.otherSkin)
                    ForEach(model.clips, id: \.name) { Text($0.label).tag($0.name) }
                }
                .onChange(of: model.w) { _, new in
                    if new == WeaponSheetModel.otherSkin && model.wSkin == nil { model.chooseOtherSkin(studio) }
                }
                if model.w == WeaponSheetModel.otherSkin, model.wSkin != nil {
                    Button("Other Skin…") { model.chooseOtherSkin(studio) }.controlSize(.small)
                }
                if let problem = model.wSkinProblem { Text(problem).font(.caption).foregroundStyle(.red) }
                if model.findingSlash {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Looking for a left-to-right slash for W…").font(.caption).foregroundStyle(.secondary)
                    }
                } else if let s = model.suggestedW {
                    Text("Left-to-right slash found: \(s)").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { studio.showWeaponSheet = false }.keyboardShortcut(.cancelAction)
                Button("Set Up") {
                    let clips = model.clips
                    func pick(_ n: UInt32) -> ClipInfo? { n == 0 ? nil : clips.first { $0.name == n } }
                    studio.showWeaponSheet = false
                    let fromSkin = model.w == WeaponSheetModel.otherSkin ? model.wSkin : nil
                    studio.setUpSpellWeapon(part: model.part, q1: pick(model.q1), q2: pick(model.q2),
                                            w: fromSkin == nil ? pick(model.w) : nil, wFrom: fromSkin)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.loading || model.clips.isEmpty || model.part.isEmpty || (model.q1 == 0 && model.q2 == 0 && model.w == 0))
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { model.load(studio) }
    }

    private func picker(_ title: String, _ selection: Binding<UInt32>) -> some View {
        Picker(title, selection: selection) {
            Text("Keep \(champion)'s own").tag(UInt32(0))
            ForEach(model.clips, id: \.name) { Text($0.label).tag($0.name) }
        }
    }
}
