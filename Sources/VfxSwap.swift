import Foundation

/// A spell's visual effects taken from another skin of the same champion (e.g. Winterblessed Camille's E on any Camille skin).
/// Each skin has a table from effect names the spells ask for ("Camille_E_hit"…) to its own effect definitions; the chosen
/// spell's entries are pointed at the other skin's definitions, which are copied into the skin's file.
enum VfxSwap {
    static let spells = ["Q", "W", "E", "R", "Passive", "Attacks"]

    /// Which spell an effect belongs to, from its name ("Camille_Skin31_E_buf" → "E"; "…_BA_…" → "Attacks").
    static func spell(of name: String) -> String? {
        let tokens = name.split(whereSeparator: { $0 == "_" || $0 == " " }).map { $0.lowercased() }
        for t in tokens.dropFirst() {
            switch t {
            case "q", "q1", "q2", "q3": return "Q"
            case "w", "w1", "w2": return "W"
            case "e", "e1", "e2": return "E"
            case "r", "r1", "r2": return "R"
            case "p", "passive": return "Passive"
            case "ba", "attack", "crit", "basicattack": return "Attacks"
            default: continue
            }
        }
        return nil
    }

    /// The resolver of a skin .bin: (object index in the bin, field index of its table).
    private static func resolver(_ bin: BinFile) -> (Int, Int)? {
        guard let props = bin.objects.first(where: { $0.cls == fnv("SkinCharacterDataProperties") }),
              case let .link(path)? = props.fields.first(where: { $0.name == fnv("mResourceResolver") || $0.name == 0x6228_6E7E })?.value,
              let o = bin.objects.firstIndex(where: { $0.path == path }),
              let f = bin.objects[o].fields.firstIndex(where: { if case .map = $0.value { return true }; return false }) else { return nil }
        return (o, f)
    }

    /// Every object a skin loads: its own and those of the .bin files it links.
    private static func loaded(_ bin: BinFile, from files: FileSource) -> [UInt32: BinObject] {
        var out: [UInt32: BinObject] = [:]
        for o in bin.objects { out[o.path] = o }
        for l in bin.links {
            guard let d = files.data(pathHash(l)), let b = try? BinFile.parse(d) else { continue }
            for o in b.objects where out[o.path] == nil { out[o.path] = o }
        }
        return out
    }

    private static func name(_ o: BinObject) -> String {
        o.fields.compactMap { if case let .string(s) = $0.value { return s }; return nil }.first ?? ""
    }

    /// `bin` (the skin being made) with the effects of each picked spell taken from another skin of the champion.
    static func apply(_ bin: BinFile, files: FileSource, champion: String, picks: [String: Int]) throws -> BinFile {
        guard !picks.isEmpty else { return bin }
        var out = bin
        guard let (ro, rf) = resolver(out), case let .map(kType, vType, own) = out.objects[ro].fields[rf].value else {
            throw FormatError("This skin has no effect table")
        }
        var table = own
        var have = loaded(out, from: files)
        var added: [BinObject] = []
        func copy(_ path: UInt32, from donor: [UInt32: BinObject]) {
            guard have[path] == nil, let o = donor[path] else { return }
            have[path] = o
            added.append(o)
            for f in o.fields { f.value.walk { if case let .link(l) = $0 { copy(l, from: donor) } } }    // child effects, materials…
        }
        for (spell, skin) in picks {
            guard let d = files.data(SkinData.binHash(champion, skin)) else { throw FormatError("Skin \(skin) not found") }
            let donorBin = try BinFile.parse(d)
            let donor = loaded(donorBin, from: files)
            guard let (dro, drf) = resolver(donorBin), case let .map(_, _, entries) = donorBin.objects[dro].fields[drf].value else { continue }
            for (key, value) in entries {
                guard case let .link(path) = value, let o = donor[path], Self.spell(of: name(o)) == spell else { continue }
                copy(path, from: donor)
                guard case let .hash(k) = key else { continue }
                if let i = table.firstIndex(where: { if case let .hash(h) = $0.0 { return h == k }; return false }) { table[i].1 = value }
                else { table.append((key, value)) }
            }
        }
        out.objects[ro].fields[rf] = BinField(name: out.objects[ro].fields[rf].name, value: .map(key: kType, val: vType, table))
        out.objects += added
        return out
    }

    /// How many effects a skin has for each spell (to show in the picker).
    static func counts(files: FileSource, champion: String, skin: Int) -> [String: Int] {
        guard let d = files.data(SkinData.binHash(champion, skin)), let bin = try? BinFile.parse(d),
              let (ro, rf) = resolver(bin), case let .map(_, _, entries) = bin.objects[ro].fields[rf].value else { return [:] }
        let objects = loaded(bin, from: files)
        var out: [String: Int] = [:]
        for (_, v) in entries {
            if case let .link(p) = v, let o = objects[p], let s = spell(of: name(o)) { out[s, default: 0] += 1 }
        }
        return out
    }
}
