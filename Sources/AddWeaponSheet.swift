import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AddWeaponModel: ObservableObject {
    @Published var source: PortSource?
    @Published var parts: [String] = []
    @Published var part = ""
    @Published var carry = true
    @Published var message = ""
    @Published var loading = false

    func choose(_ studio: Studio) {
        let p = NSOpenPanel()
        p.allowedContentTypes = [UTType(filenameExtension: "fantome") ?? .zip, .zip]
        p.message = "Choose a custom skin (.fantome) whose weapon you want"
        guard p.runModal() == .OK, let url = p.url else { return }
        loading = true
        message = "Reading \(url.lastPathComponent)…"
        let dir = studio.championsDir
        Task {
            do {
                let (src, names) = try await Task.detached { () -> (PortSource, [String]) in
                    let info = try FantomeInfo.inspect(url, championsDir: dir)
                    let src = PortSource(modWad: info.modWad, champion: info.champion, skin: info.skins.first ?? 0, label: info.name)
                    let skin = try SkinData.load(try src.open(championsDir: dir), champion: src.champion, num: src.skin)
                    return (src, skin.mesh.parts.map(\.name))
                }.value
                self.source = src
                self.parts = names
                let words = ["weapon", "spear", "sword", "blade", "katana", "axe", "scythe", "staff", "lance", "hammer"]
                self.part = names.first { n in words.contains { n.lowercased().contains($0) } } ?? names.first ?? ""
                self.message = "\(src.label) (\(src.champion))"
            } catch {
                self.source = nil
                self.message = error.localizedDescription
            }
            self.loading = false
        }
    }
}

/// Take a weapon from another skin (e.g. Zaahen's spear) and put it in the champion's hand for good.
struct AddWeaponSheet: View {
    @ObservedObject var studio: Studio
    @StateObject private var model = AddWeaponModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Weapon from Another Skin").font(.headline)
            Text("The weapon goes in \(studio.champion ?? "the champion")'s hand, held the way that skin holds it, and stays there. "
                 + "Weapon on Spells… then gives Q, Q2 and W that skin's moves.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Choose .fantome…") { model.choose(studio) }
                if model.loading { ProgressView().controlSize(.small) }
                Text(model.message).lineLimit(1).foregroundStyle(.secondary)
            }
            Picker("Weapon part", selection: $model.part) {
                ForEach(model.parts, id: \.self) { Text($0).tag($0) }
            }
            .disabled(model.parts.isEmpty)
            Toggle(isOn: $model.carry) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Carry it while idle and running")
                    Text("Her arms move like that skin's when standing and running, so the weapon is held naturally.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { studio.showAddWeaponSheet = false }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    guard let s = model.source else { return }
                    studio.showAddWeaponSheet = false
                    studio.addWeapon(from: s, part: model.part, carry: model.carry)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.source == nil || model.part.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
