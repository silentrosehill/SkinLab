import SwiftUI

/// Pick, per spell, another skin of the champion whose effects to use (the skin's own by default).
struct VfxSheet: View {
    @ObservedObject var studio: Studio

    private func binding(_ spell: String) -> Binding<Int> {
        Binding(get: { studio.vfxPicks[spell] ?? -1 },
                set: { studio.vfxPicks[spell] = $0 < 0 ? nil : $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Spell Effects").font(.headline)
            Text("Use the visual effects of another \(studio.champion ?? "") skin for some spells, e.g. Winterblessed's E on your skin. "
                 + "The spells work the same; only how they look changes. Sounds stay the skin's own.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(VfxSwap.spells, id: \.self) { spell in
                Picker(spell == "Attacks" ? "Attacks" : spell == "Passive" ? "Passive" : "\(spell) effects", selection: binding(spell)) {
                    Text("This skin's own").tag(-1)
                    ForEach(studio.skins.filter { $0.id != studio.skin }) { s in Text(s.name).tag(s.id) }
                }
            }
            HStack {
                Button("Reset All") { studio.vfxPicks = [:] }.disabled(studio.vfxPicks.isEmpty)
                Spacer()
                Button("Done") { studio.showVfxSheet = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
