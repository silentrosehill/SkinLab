import Foundation
import SwiftUI
import AppKit
import CoreImage
import simd

/// Color changes for one texture. All zero / one = untouched.
struct Adjust: Equatable {
    var hue: Double = 0           // degrees
    var saturation: Double = 1
    var brightness: Double = 0
    var contrast: Double = 1
    var tint: NSColor = .white
    var tintAmount: Double = 0

    var isIdentity: Bool { self == Adjust() }
}

/// One texture of the loaded skin and what you've done to it.
final class TextureSlot: ObservableObject, Identifiable {
    let id: UInt64                  // its path hash in the game's files
    let originalData: Data
    let original: RGBAImage
    var parts: [String]             // model parts that use it
    /// Set for textures brought over by a port: saved as a new file at this path.
    var exportPath: String?
    @Published var adjust = Adjust()
    @Published var replacement: CGImage? { didSet { texPalette = nil } }
    @Published private(set) var edited: CGImage?
    /// Hand-painted fixes over the texture (nil until painted on).
    var paint: PaintLayer?
    /// The texture under the paint (recolors applied), and as shown (with the paint), RGBA: what brushes work from.
    private(set) var baseRGBA: [UInt8] = []
    private(set) var shownRGBA: [UInt8] = []
    private var baseImage: CGImage?
    var size: (width: Int, height: Int) { (baseImage?.width ?? original.width, baseImage?.height ?? original.height) }
    /// Picture color each of this texture's color regions turns into (-1 keeps it); nil when not used.
    @Published var styleMapping: [Int]?
    private var styleLUT: Data?
    private var texPalette: Palette?

    /// This texture's main color regions.
    var palette: Palette {
        if let texPalette { return texPalette }
        let p = (replacement ?? original.cgImage).map { Style.palette(ofTexture: $0) } ?? Palette(colors: [], weights: [])
        texPalette = p
        return p
    }

    /// Recolors toward a picture's palette (nil turns it off). `remap` picks the color pairs again.
    func applyStyle(_ picture: Palette?, strength: Double, keepSkin: Bool, remap: Bool) {
        guard let picture else { styleMapping = nil; styleLUT = nil; return }
        if remap || styleMapping == nil || styleMapping!.count != palette.colors.count {
            styleMapping = Style.autoMap(texture: palette, picture: picture, keepSkin: keepSkin)
        }
        styleLUT = Style.lut(texture: palette, picture: picture, mapping: styleMapping!, strength: Float(strength))
    }

    /// Cycles which picture color one region becomes (… → keep original → first picture color → …).
    func cycle(_ region: Int, picture: Palette, strength: Double) {
        guard var m = styleMapping, region < m.count else { return }
        m[region] = m[region] + 1 >= picture.colors.count ? -1 : m[region] + 1
        styleMapping = m
        styleLUT = Style.lut(texture: palette, picture: picture, mapping: m, strength: Float(strength))
    }

    init(id: UInt64, data: Data, image: RGBAImage, parts: [String]) {
        self.id = id
        originalData = data
        original = image
        self.parts = parts
        edited = image.cgImage
    }

    var isChanged: Bool { replacement != nil || !adjust.isIdentity || styleMapping != nil || !(paint?.isEmpty ?? true) }

    /// The paint layer, made on first use at the texture's size.
    func paintLayer() -> PaintLayer {
        if baseImage == nil { baseImage = edited ?? original.cgImage }     // never recolored yet: the texture as it is
        let (w, h) = size
        if let paint, paint.width == w, paint.height == h { return paint }
        let p = PaintLayer(width: w, height: h)
        paint = p
        if baseRGBA.count != w * h * 4, let baseImage { baseRGBA = PaintLayer.rgba(baseImage, width: w, height: h) }
        if shownRGBA.count != w * h * 4 { shownRGBA = baseRGBA }
        return p
    }

    /// Puts the paint back on top after a brush stroke (fast: the recolor isn't redone).
    func repaint() {
        guard let paint, let baseImage else { edited = baseImage; return }
        let (w, h) = (baseImage.width, baseImage.height)
        if baseRGBA.count != w * h * 4 { baseRGBA = PaintLayer.rgba(baseImage, width: w, height: h) }
        shownRGBA = paint.composite(over: baseRGBA)
        edited = PaintLayer.image(shownRGBA, width: w, height: h)
    }

    var fileExtension: String { TextureFile.kind(of: originalData) == .dds ? "dds" : "tex" }

    /// What goes in the mod for this texture, or nil if it doesn't need to.
    func modFile() -> (hash: UInt64, ext: String, data: Data)? {
        if let exportPath {
            guard let data = isChanged ? encoded() : originalData else { return nil }
            return (pathHash(exportPath), fileExtension, data)
        }
        guard isChanged, let data = encoded() else { return nil }
        return (id, fileExtension, data)
    }

    private static let ci = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

    /// Re-renders the edited image from the original (or replacement) and the sliders.
    func render() {
        guard let base = replacement ?? original.cgImage else { return }
        var img = CIImage(cgImage: base)
        if let styleLUT {
            img = img.applyingFilter("CIColorCubeWithColorSpace", parameters: [
                "inputCubeDimension": 32, "inputCubeData": styleLUT,
                "inputColorSpace": CGColorSpace(name: CGColorSpace.sRGB)!,
            ])
        }
        if adjust.hue != 0 {
            img = img.applyingFilter("CIHueAdjust", parameters: [kCIInputAngleKey: adjust.hue * .pi / 180])
        }
        if adjust.saturation != 1 || adjust.brightness != 0 || adjust.contrast != 1 {
            img = img.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: adjust.saturation, kCIInputBrightnessKey: adjust.brightness,
                kCIInputContrastKey: adjust.contrast,
            ])
        }
        if adjust.tintAmount > 0 {
            img = img.applyingFilter("CIColorMonochrome", parameters: [
                kCIInputColorKey: CIColor(color: adjust.tint) ?? CIColor.white, kCIInputIntensityKey: adjust.tintAmount,
            ])
        }
        baseImage = Self.ci.createCGImage(img, from: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        baseRGBA = []
        if paint != nil { repaint() } else { edited = baseImage }
    }

    func reset() {
        paint = nil
        adjust = Adjust()
        replacement = nil
        styleMapping = nil
        styleLUT = nil
        render()
    }

    /// The edited texture in the game's own file format, at the original size.
    func encoded() -> Data? {
        guard let edited, let rgba = RGBAImage(cgImage: edited, width: original.width, height: original.height) else { return nil }
        return TextureFile.encode(rgba, like: originalData)
    }
}

struct SkinChoice: Identifiable, Hashable {
    let id: Int        // skin number
    let name: String
}

/// Porting a model that's only a weapon (no body): it goes to the weapon library instead.
struct WeaponOnlyModel: Error {}

@MainActor
final class Studio: ObservableObject {
    @Published var gamePath: String = UserDefaults.standard.string(forKey: "gamePath")
        ?? "/Applications/League of Legends.app/Contents/LoL/Game" {
        didSet { UserDefaults.standard.set(gamePath, forKey: "gamePath"); loadChampions() }
    }
    @Published private(set) var champions: [String] = []
    @Published var champion: String?
    @Published private(set) var skins: [SkinChoice] = []
    @Published var skin: Int?
    @Published private(set) var mesh: SkinnedMesh? { didSet { meshVersion += 1 } }
    /// The model in its rest pose while a frozen debug pose is shown (saving always uses the rest pose).
    private var restMesh: SkinnedMesh?
    /// Bumped whenever the model's geometry changes, so the 3D view rebuilds it.
    private(set) var meshVersion = 0
    @Published private(set) var textures: [TextureSlot] = []
    /// Which texture each model part uses.
    @Published private(set) var partTexture: [String: UInt64] = [:]
    @Published var search = ""
    /// Parts hidden in the 3D preview (the exported skin is unaffected).
    @Published var hiddenParts: Set<String> = []
    @Published var status = ""
    @Published var busy = false
    @Published var modName = ""
    @Published var modAuthor = UserDefaults.standard.string(forKey: "modAuthor") ?? "" {
        didSet { UserDefaults.standard.set(modAuthor, forKey: "modAuthor") }
    }
    /// Bumped whenever a texture changes, so the 3D view refreshes.
    @Published var revision = 0
    /// Set while the model on screen is another skin ported onto this one.
    @Published private(set) var portedFrom: String?
    @Published var showPortSheet = false

    // MARK: Animation preview state
    struct PartEvent {
        let frame: Float
        let show: [String]
        let hide: [String]
    }
    struct Playback {
        let label: String
        let clip: AnimClip
        let events: [PartEvent]
        let loop: Bool
        let started: Date
    }
    @Published private(set) var playback: Playback?
    @Published private(set) var clipList: [ClipInfo] = []
    @Published var loopPlayback = false
    /// Animations replaced for this skin (clip name → animation), e.g. the katana slices on Q.
    var clipOverrides: [UInt32: (clip: AnimClip, events: [PartEvent])] = [:]
    /// What the current port was made from (to read its animations again).
    private(set) var lastPortSource: PortSource?
    /// A weapon drawn for spells (Q, W): the part, its new animations and show/hide events.
    @Published private(set) var spellWeapon: SpellWeapon?
    @Published var showWeaponSheet = false
    /// Spell effects taken from other skins of the champion: spell ("E") → skin number.
    @Published var vfxPicks: [String: Int] = [:]
    @Published var showVfxSheet = false
    // MARK: Paint state
    @Published var paintMode = false { didSet { if paintMode { playback = nil } } }
    @Published var paintTool: PaintLayer.Tool = .paint
    @Published var paintColor = CGColor(srgbRed: 0.9, green: 0.85, blue: 0.8, alpha: 1)
    @Published var brushSize = 18.0          // on screen, in points
    @Published var brushStrength = 0.5
    private var lastPainted: TextureSlot?
    var canUndoPaint: Bool { lastPainted?.paint?.canUndo ?? false }
    /// "Colors from a picture": the picture, its palette, and how strongly it's applied.
    @Published private(set) var stylePicture: CGImage?
    @Published private(set) var stylePalette: Palette?
    @Published private(set) var styleFoundSubject = false
    @Published var styleStrength = 1.0
    @Published var keepSkin = true

    private var wad: Wad?
    private var target: SkinData?
    private var portHide: [String] = []
    /// Weapon swap: the skin's weapon parts, and the champion's thrown weapons (spell-effect models) they replace too.
    private var swappedParts: [String] = []
    /// Weapons of the skin put in the champion's hands by the port (always shown).
    @Published private(set) var heldWeapons: [String] = []
    private var thrownWeapons: [ThrownWeapon] = []
    private var portLegs: (plan: LegPlan, skeleton: Skeleton)?
    /// With shorter legs: drawn bigger in game (and in the preview) to keep the champion's usual height.
    @Published private(set) var sizeFactor: Float = 1
    private var skinNameCache: [String: [Int: String]] = [:]

    init() {
        loadChampions()
        // A Camille workshop: she opens right away (other champions stay in the sidebar).
        let first = UserDefaults.standard.string(forKey: "startChampion") ?? "Camille"
        if champions.contains(first), ProcessInfo.processInfo.environment["SKINLAB_TEST"] == nil { open(champion: first) }
    }

    var championsDir: URL { URL(fileURLWithPath: gamePath).appendingPathComponent("DATA/FINAL/Champions") }
    var skinName: String { skins.first { $0.id == skin }?.name ?? "Skin \(skin ?? 0)" }

    func loadChampions() {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: championsDir.path)) ?? []
        // "Camille.wad.client", not the voice-over/locale ones like "Camille.en_US.wad.client"
        champions = files.filter { $0.hasSuffix(".wad.client") && $0.split(separator: ".").count == 3 }
            .map { String($0.dropLast(".wad.client".count)) }
            .sorted()
        status = champions.isEmpty ? "League not found. Set the game folder with Game Folder…" : "\(champions.count) champions"
    }

    /// Skin numbers that exist for a champion, with names when online.
    func skinList(for name: String) async -> [SkinChoice] {
        let url = championsDir.appendingPathComponent("\(name).wad.client")
        let nums: [Int] = await Task.detached {
            guard let wad = try? Wad(url: url) else { return [] }
            return (0 ..< 200).filter { wad.contains(SkinData.binHash(name, $0)) }
        }.value
        let names = await skinNames(for: name)
        return nums.map { SkinChoice(id: $0, name: names[$0] ?? ($0 == 0 ? "Base" : names.isEmpty ? "Skin \($0)" : "Skin \($0) (chroma)")) }
    }

    /// Real skin names from Riot's public Data Dragon (optional; numbers are used offline).
    func skinNames(for name: String) async -> [Int: String] {
        if let cached = skinNameCache[name] { return cached }
        guard let vURL = URL(string: "https://ddragon.leagueoflegends.com/api/versions.json"),
              let (vData, _) = try? await URLSession.shared.data(from: vURL),
              let version = (try? JSONSerialization.jsonObject(with: vData) as? [String])?.first,
              let url = URL(string: "https://ddragon.leagueoflegends.com/cdn/\(version)/data/en_US/champion/\(name).json"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let champ = (json["data"] as? [String: Any])?.values.first as? [String: Any],
              let list = champ["skins"] as? [[String: Any]] else { return [:] }
        var names: [Int: String] = [:]
        for s in list { if let num = s["num"] as? Int, let n = s["name"] as? String { names[num] = n == "default" ? "Base" : n } }
        skinNameCache[name] = names
        return names
    }

    func open(champion name: String) {
        champion = name
        vfxPicks = [:]
        skin = nil
        skins = []
        mesh = nil
        textures = []
        portedFrom = nil
        busy = true
        status = "Reading \(name)…"
        let url = championsDir.appendingPathComponent("\(name).wad.client")
        Task {
            do {
                let wad = try await Task.detached { try Wad(url: url) }.value
                self.wad = wad
                let nums = (0 ..< 200).filter { wad.contains(SkinData.binHash(name, $0)) }
                self.skins = nums.map { SkinChoice(id: $0, name: $0 == 0 ? "Base" : "Skin \($0)") }
                self.busy = false
                if let first = nums.first { self.open(skin: first) }
                let full = await self.skinList(for: name)
                if self.champion == name, !full.isEmpty { self.skins = full }
            } catch {
                self.busy = false
                self.status = "Couldn't read \(name): \(error.localizedDescription)"
            }
        }
    }

    func open(skin num: Int) {
        guard let wad, let champion else { return }
        skin = num
        busy = true
        status = "Loading skin…"
        hiddenParts = []
        portedFrom = nil
        portHide = []
        swappedParts = []
        heldWeapons = []
        thrownWeapons = []
        extraWeapon = nil
        weaponBone = nil
        carryClips = [:]
        portLegs = nil
        lastPortSource = nil
        spellWeapon = nil
        sizeFactor = 1
        Task {
            do {
                let data = try await Task.detached { try SkinData.load(wad, champion: champion, num: num) }.value
                guard self.champion == champion, self.skin == num else { return }
                self.target = data
                self.playback = nil
                self.clipOverrides = [:]
                self.clipList = data.clips(wad)
                self.show(mesh: data.mesh, partTexture: data.partTexture, textures: data.textures, order: data.textureOrder, newPaths: [:])
                self.busy = false
                if self.modName.isEmpty || self.modName.hasPrefix("My ") { self.modName = "My \(self.skinName) \(champion)" }
                let missing = data.mesh.parts.filter { data.partTexture[$0.name] == nil }.count
                self.status = "\(data.mesh.parts.count) parts, \(data.textures.count) textures"
                    + (missing > 0 ? " (\(missing) parts have no texture found)" : "")
            } catch {
                self.mesh = nil
                self.textures = []
                self.busy = false
                self.status = "Couldn't load skin \(num): \(error.localizedDescription)"
            }
        }
    }

    private func show(mesh: SkinnedMesh, partTexture: [String: UInt64], textures: [UInt64: (data: Data, image: RGBAImage)],
                      order: [UInt64], newPaths: [UInt64: String]) {
        var slots: [TextureSlot] = []
        for h in order {
            guard let t = textures[h] else { continue }
            let slot = TextureSlot(id: h, data: t.data, image: t.image,
                                   parts: mesh.parts.map(\.name).filter { partTexture[$0] == h })
            slot.exportPath = newPaths[h]
            slots.append(slot)
        }
        restMesh = nil
        self.mesh = mesh
        self.partTexture = partTexture
        self.textures = slots
        hiddenParts = []
        if stylePalette != nil { restyle(remap: true) }
        revision += 1
    }

    // MARK: Colors from a picture

    func chooseStylePicture() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        p.message = "Choose a picture of a character, an outfit or anything with colors you like"
        guard p.runModal() == .OK, let url = p.url else { return }
        useStylePicture(url)
    }

    func useStylePicture(_ url: URL) {
        guard let img = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            status = "Couldn't open that picture"
            return
        }
        busy = true
        status = "Reading the picture's colors…"
        Task {
            let (palette, found) = await Task.detached { Style.palette(ofPicture: img) }.value
            self.stylePicture = img
            self.stylePalette = palette
            self.styleFoundSubject = found
            self.busy = false
            self.restyle(remap: true)
            self.status = found ? "Using the colors of the character in the picture" : "No character found in the picture: using all of its colors"
        }
    }

    /// Re-applies the picture's colors to every texture using them (all of them when `remap`).
    func restyle(remap: Bool) {
        let debug = ProcessInfo.processInfo.environment["SKINLAB_DEBUG"] != nil
        func fmt(_ p: Palette) -> String {
            zip(p.colors, p.weights).map { String(format: "L%.0f a%.0f b%.0f (%.0f%%)", $0.x, $0.y, $0.z, $1 * 100) }.joined(separator: " | ")
        }
        if debug, let stylePalette { print("picture: " + fmt(stylePalette)) }
        for slot in textures where remap || slot.styleMapping != nil {
            slot.applyStyle(stylePalette, strength: styleStrength, keepSkin: keepSkin, remap: remap)
            slot.render()
            if debug { print("texture \(slot.parts): " + fmt(slot.palette) + " map \(slot.styleMapping ?? [])") }
        }
        revision += 1
    }

    func setStyle(_ on: Bool, for slot: TextureSlot) {
        slot.applyStyle(on ? stylePalette : nil, strength: styleStrength, keepSkin: keepSkin, remap: true)
        changed(slot)
    }

    func cycle(_ region: Int, of slot: TextureSlot) {
        guard let stylePalette else { return }
        slot.cycle(region, picture: stylePalette, strength: styleStrength)
        changed(slot)
    }

    func clearStyle() {
        stylePalette = nil
        stylePicture = nil
        for slot in textures where slot.styleMapping != nil {
            slot.applyStyle(nil, strength: 0, keepSkin: keepSkin, remap: false)
            slot.render()
        }
        revision += 1
    }

    // MARK: Porting

    /// Puts another skin's model on the current skin.
    func port(from source: PortSource, keep: Set<KeepRegion>, naturalLegs: Bool = false, keepHeight: Bool = true, swapWeapon: Bool = true) {
        let dir = championsDir
        lastPortSource = source
        port(label: source.label, sourceName: source.champion, keep: keep, naturalLegs: naturalLegs, keepHeight: keepHeight,
             swapWeapon: swapWeapon) {
            let files = try source.open(championsDir: dir)
            let data = try SkinData.load(files, champion: source.champion, num: source.skin, needSkeleton: true)
            return (data, files)
        }
    }

    /// A skin's spell animations (Q first), for finding how it holds its weapons.
    nonisolated static func spellClips(_ skin: SkinData, _ files: FileSource) -> [AnimClip] {
        skin.clips(files).filter { $0.file != nil && $0.label.lowercased().contains("spell1") }.prefix(3)
            .compactMap { $0.file.flatMap(files.data).flatMap { try? AnimClip.decode($0) } }
    }

    /// A skin's attack animations (where it holds its weapon), for fitting a swapped weapon.
    nonisolated static func attackClips(_ skin: SkinData, _ files: FileSource) -> [AnimClip] {
        let clips = skin.clips(files).filter { $0.file != nil }
        let attacks = clips.filter { c in ["attack", "crit"].contains { c.label.lowercased().contains($0) } && !c.label.lowercased().contains("to") }
        return (attacks.isEmpty ? Array(clips.prefix(3)) : Array(attacks.prefix(4)))
            .compactMap { $0.file.flatMap(files.data).flatMap { try? AnimClip.decode($0) } }
    }

    /// Puts a character model from outside League (an MMD .pmx, like the official Genshin Impact models, or a Blender .blend)
    /// on the current skin.
    func port(model url: URL, keep: Set<KeepRegion>, naturalLegs: Bool = false, keepHeight: Bool = true) {
        let stem = url.deletingPathExtension().lastPathComponent
        // A Chinese / Japanese name garbled by unzipping ("Ω£" for "剑") shown as it was.
        // (the shortest reading: two garbled letters make one Chinese character)
        let name = ModelImport.ungarbled(stem).filter { $0.unicodeScalars.contains { $0.value >= 0x3040 } && !$0.contains("\u{FFFD}") }
            .min { $0.count < $1.count } ?? stem
        let safe = String(name.lowercased().filter { $0.isLetter || $0.isNumber }.prefix(24))
        lastPortSource = nil
        port(label: name, sourceName: safe.isEmpty ? "model" : safe, keep: keep, naturalLegs: naturalLegs, keepHeight: keepHeight,
             swapWeapon: false) {
            (try ModelImport.loadAny(url), nil)
        }
    }

    /// Builds a model from a character sheet (front, side, back… views) and puts it on the current skin.
    func port(sheet url: URL, keep: Set<KeepRegion>, naturalLegs: Bool = false, keepHeight: Bool = true) {
        let name = url.deletingPathExtension().lastPathComponent
        let safe = String(name.lowercased().filter { $0.isLetter || $0.isNumber }.prefix(24))
        port(label: name, sourceName: safe.isEmpty ? "sheet" : safe, keep: keep, naturalLegs: naturalLegs, keepHeight: keepHeight,
             swapWeapon: false) {
            guard let img = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw FormatError("Couldn't open that picture")
            }
            return (try Reconstruct.build(try Sheet.read(img), name: safe), nil)
        }
    }

    private func port(label: String, sourceName: String, keep: Set<KeepRegion>, naturalLegs: Bool, keepHeight: Bool, swapWeapon: Bool,
                      load: @escaping () throws -> (SkinData, FileSource?)) {
        guard let target, let champion else { return }
        let game = wad
        let skinNumber = skin ?? 0
        nonisolated(unsafe) var heldNames: [String] = []
        nonisolated(unsafe) var foundWeapons: [WeaponLibrary.Found] = []
        busy = true
        status = "Porting \(label)…"
        Task {
            do {
                let (r, swap, thrown) = try await Task.detached { () -> (PortResult, WeaponSwap?, [ThrownWeapon]) in
                    let (data, files) = try load()
                    // Weapons it has go to the weapon library; a model that's only a weapon isn't ported.
                    if WeaponLibrary.hasNoBody(data) {
                        foundWeapons = WeaponLibrary.find(in: data, wholeModel: true, modelName: label)
                        throw WeaponOnlyModel()
                    }
                    foundWeapons = WeaponLibrary.find(in: data)
                    if ProcessInfo.processInfo.environment["SKINLAB_RAW"] != nil {   // debug: the source as-is
                        return (PortResult(mesh: data.mesh, partTexture: data.partTexture, newTexturePaths: [:], textures: data.textures,
                                           textureOrder: data.textureOrder, hideAtStart: [], matchedBones: 0, sourceBones: 0), nil, [])
                    }
                    guard let ts = target.skeleton else { throw FormatError("\(champion)'s skeleton couldn't be read") }
                    // The champion's weapon becomes the skin's weapon (held like the skin holds it, moving like the old one).
                    var swap: WeaponSwap?
                    if swapWeapon, let files, let game, let ss = data.skeleton {
                        swap = WeaponSwap.plan(source: data, sourceClips: Self.attackClips(data, files), target: target,
                                               targetClips: Self.attackClips(target, game), scale: Retarget.bodyScale(source: ss, target: ts))
                    }
                    // Weapons the champion's spells throw (Gragas's barrels) become the new weapon too.
                    let thrown = swap != nil && game != nil ? ThrownWeapon.find(in: game!, champion: champion, skin: skinNumber) : []
                    // A champion without a weapon (Camille): the skin's weapons go in her hands, held like the skin holds them.
                    var held: [WeaponSwap.Held] = []
                    if swapWeapon, swap == nil, let files, let ss = data.skeleton {
                        held = WeaponSwap.hold(source: data, sourceClips: Self.attackClips(data, files) + Self.spellClips(data, files),
                                               target: target, scale: Retarget.bodyScale(source: ss, target: ts))
                    }
                    let result = try Porter.port(source: data, target: target, keep: keep, naturalLegs: naturalLegs, weapon: swap, held: held,
                                                 sourceName: sourceName, targetName: champion)
                    heldNames = held.map(\.name)
                    return (result, swap, thrown)
                }.value
                let collected = self.weaponLibrary.add(foundWeapons, origin: label)
                self.swappedParts = swap?.parts ?? []
                self.heldWeapons = heldNames
                self.extraWeapon = nil
                self.weaponBone = nil
                self.carryClips = [:]
                self.thrownWeapons = thrown
                if ProcessInfo.processInfo.environment["SKINLAB_TEST"] != nil {
                    print("weapon swap:", swap?.label ?? "-", "thrown:", thrown.map { "\($0.meshPath) + \($0.texturePath)" })
                }
                self.playback = nil
                self.clipOverrides = [:]
                self.spellWeapon = nil
                self.portLegs = r.legPlan.flatMap { p in r.skeleton.map { (p, $0) } }    // before show(): the view binds to it
                self.show(mesh: r.mesh, partTexture: r.partTexture, textures: r.textures, order: r.textureOrder, newPaths: r.newTexturePaths)
                self.portedFrom = label
                self.portHide = r.hideAtStart.filter { !r.farParts.contains($0) }
                self.sizeFactor = keepHeight ? r.heightRatio : 1
                self.busy = false
                self.hiddenParts = Set(r.hideAtStart).union(r.farParts)
                self.modName = "\(label) on \(champion)"
                if ProcessInfo.processInfo.environment["SKINLAB_TEST"] != nil { print("port:", label, "drop", r.legPlan?.drop ?? 0, "size", self.sizeFactor) }
                self.status = "Ported \(label): \(r.matchedBones) of \(r.sourceBones) bones matched"
                    + (swap.map { ", weapon swapped (\($0.label))" } ?? "")
                    + (heldNames.isEmpty ? "" : ", weapons in hands (\(heldNames.joined(separator: ", ")))")
                    + (thrown.isEmpty ? "" : ", also in \(thrown.count) spell effect\(thrown.count == 1 ? "" : "s")")
                    + (r.farParts.isEmpty ? "" : ", \(r.farParts.count) far-off prop(s) left out (Parts menu to bring back)")
                    + (collected.isEmpty ? "" : ", \(collected.count) weapon\(collected.count == 1 ? "" : "s") added to Weapons…")
                    + (r.legPlan.map { _ in keepHeight && r.heightRatio > 1.01
                        ? String(format: ", normal proportions (drawn %.0f%% bigger to keep the usual height)", (r.heightRatio - 1) * 100)
                        : ", normal proportions" } ?? (naturalLegs ? ", legs already match" : ""))
            } catch is WeaponOnlyModel {
                self.busy = false
                let added = self.weaponLibrary.add(foundWeapons, origin: label)
                self.status = added.isEmpty ? "\(label) is a weapon (no body), already in Weapons…"
                    : "\(label) is a weapon, not a character: added to Weapons… (pick it there to put it in her hand)"
            } catch {
                self.busy = false
                self.status = "Couldn't port: \(error.localizedDescription)"
            }
        }
    }

    func undoPort() {
        if let skin { open(skin: skin) }
    }

    /// Debug: checks every skin .bin of a champion reads and writes back byte for byte.
    nonisolated static func roundTrip(gamePath: String, champion: String) {
        guard let wad = try? Wad(url: URL(fileURLWithPath: gamePath).appendingPathComponent("DATA/FINAL/Champions/\(champion).wad.client")) else { return }
        var ok = 0, bad = 0
        for n in 0 ..< 200 {
            let h = pathHash("data/characters/\(champion.lowercased())/skins/skin\(n).bin")
            guard wad.contains(h), let data = try? wad.read(h) else { continue }
            if let f = try? BinFile.parse(data), f.serialized() == data { ok += 1 } else { bad += 1; print("  mismatch skin\(n)") }
        }
        print("\(champion): \(ok) identical, \(bad) different")
    }

    /// Debug: prints a skin's skeleton and model bounds.
    nonisolated static func dump(gamePath: String, champion: String, skin: Int) {
        do {
            let wad = try Wad(url: URL(fileURLWithPath: gamePath).appendingPathComponent("DATA/FINAL/Champions/\(champion).wad.client"))
            let objects = try Bin.parse(try wad.read(pathHash("data/characters/\(champion.lowercased())/skins/skin\(skin).bin")))
            guard let mp = objects.first(where: { $0.cls == fnv("SkinCharacterDataProperties") })?["skinMeshProperties"],
                  let skn = mp["simpleSkin"]?.fileHash, let skl = mp["skeleton"]?.fileHash else { print("no mesh props"); return }
            let mesh = try SkinnedMesh.parse(try wad.read(skn))
            let sk = try Skeleton.parse(try wad.read(skl))
            let lo = mesh.positions.reduce(SIMD3<Float>(repeating: .greatestFiniteMagnitude)) { simd_min($0, $1) }
            let hi = mesh.positions.reduce(SIMD3<Float>(repeating: -.greatestFiniteMagnitude)) { simd_max($0, $1) }
            let known = ["simpleSkin", "skeleton", "texture", "material", "materialOverride", "initialSubmeshToHide",
                         "initialSubmeshShadowsToHide", "submesh", "skinScale", "selfIllumination", "usesSkinVO", "boundingCylinderHeight",
                         "castShadows", "reflectionMap", "emissiveTexture", "fresnel", "brushAlphaOverride", "rigPoseModifierData",
                         "initialSubmeshMouseOversToHide", "forceDrawLast", "allowCharacterInking", "enablePicking"]
            func describe(_ v: BinValue, _ depth: Int) -> String {
                switch v {
                case let .string(s): return "string \"\(s)\""
                case let .file(h): return String(format: "file %016llx", h)
                case let .link(l): return String(format: "link %08x", l)
                case let .list(k, e, items): return String(format: "list(0x%02x of 0x%02x) x%d", k, e, items.count) + (depth < 2 ? " [" + items.prefix(4).map { describe($0, depth + 1) }.joined(separator: "; ") + "]" : "")
                case let .embed(k, c, f): return String(format: "embed(0x%02x cls %08x){", k, c) + f.map { fld in (known.first { fnv($0) == fld.name } ?? String(format: "%08x", fld.name)) + ": " + describe(fld.value, depth + 1) }.joined(separator: ", ") + "}"
                case let .raw(t, d): return String(format: "raw 0x%02x (%d bytes)", t, d.count)
                default: return "\(v.typeByte)"
                }
            }
            print(describe(mp, 0))
            print("skn trailing bytes: \(mesh.trailingBytes)")
            print("mesh bounds \(lo) .. \(hi), parts: \(mesh.parts.map(\.name))")
            print("influences \(sk.influences.count), joints \(sk.joints.count)")
            for (i, j) in sk.joints.enumerated() {
                let p = j.position
                let parentPos = j.parent >= 0 ? sk.joints[j.parent].position : .zero
                print(String(format: "%3d %-28@ parent %3d  pos %7.1f %7.1f %7.1f  local %6.1f %6.1f %6.1f (len %5.1f vs %5.1f) elf %@",
                             i, j.name as NSString, j.parent, p.x, p.y, p.z, j.local.x, j.local.y, j.local.z,
                             simd_length(j.local), simd_distance(p, parentPos), (Skeleton.elf(j.name) == j.nameHash ? "ok" : "MISMATCH") as NSString))
            }
        } catch { print("error: \(error)") }
    }

    /// This skin's animation graph rewritten: leg-adjusted copies of its animations (normal proportions),
    /// replaced clips (e.g. Q slices) and added show/hide events. Returns every file to put in the mod.
    nonisolated static func animationFiles(target: SkinData, wad: Wad, champion: String, skin: Int,
                                           legs: (plan: LegPlan, skeleton: Skeleton)?, overrides: [UInt32: Data],
                                           events: [UInt32: [GraphEdit.PartEvent]]) throws -> [(UInt64, String, Data)] {
        var out: [(UInt64, String, Data)] = []
        var overridePaths: [UInt32: String] = [:]
        for (clip, data) in overrides {
            let p = String(format: "ASSETS/Characters/%@/Skins/SkinLab/Animations/Skin%d_clip_%08x.anm", champion, skin, clip)
            overridePaths[clip] = p
            out.append((pathHash(p), "anm", data))
        }
        let ours = Set(overridePaths.values.map(pathHash))
        var newPath: [UInt64: String] = [:]
        func isAnimation(_ h: UInt64) -> Bool {
            guard let e = wad.entries[h], e.size > 0, let d = try? wad.read(h) else { return false }
            return d.starts(with: Data("r3d2anmd".utf8)) || d.starts(with: Data("r3d2canm".utf8))
        }
        func renamed(_ h: UInt64) -> String {
            if let p = newPath[h] { return p }
            let p = String(format: "ASSETS/Characters/%@/Skins/SkinLab/Animations/Skin%d_%016llx.anm", champion, skin, h)
            newPath[h] = p
            return p
        }
        for link in target.bin.links where link.lowercased().contains("/animations/") {
            let binHash = pathHash(link)
            guard let data = wad.data(binHash) else { continue }
            var bin = GraphEdit.edited(try BinFile.parse(data), files: overridePaths, events: events)
            if legs != nil {
                var fileChecks: [UInt64: Bool] = [:]
                for i in bin.objects.indices {
                    bin.objects[i].fields = bin.objects[i].fields.map { f in
                        BinField(name: f.name, value: f.value.mapped { v in
                            switch v {
                            case let .string(s) where s.lowercased().hasSuffix(".anm") && !ours.contains(pathHash(s)):
                                return .string(renamed(pathHash(s)))
                            case let .file(h) where !ours.contains(h):
                                if fileChecks[h] == nil { fileChecks[h] = isAnimation(h) }
                                return fileChecks[h]! ? .file(pathHash(renamed(h))) : nil
                            default:
                                return nil
                            }
                        })
                    }
                }
            }
            out.append((binHash, "bin", bin.serialized()))
        }
        if let legs {
            let (joints, change) = legs.plan.animationChange(legs.skeleton)
            for (old, path) in newPath {
                guard let data = wad.data(old) else { continue }
                out.append((pathHash(path), "anm", try AnimEdit.edit(data, joints: joints, change: change)))
            }
        }
        return out
    }

    // MARK: Weapon drawn for spells

    /// The weapon choice meaning "the weapons the port put in the hands".
    nonisolated static let heldPart = "‹weapons in hands›"

    // MARK: Weapon library

    let weaponLibrary = WeaponLibrary()
    @Published var showWeaponLibrary = false

    /// Puts a weapon of the library in her hand for good, with a style's grip, idle/run carry and Q moves: the spear
    /// style takes Zaahen's, the sword style the Ayaka skin's. W keeps another skin's W if one was set.
    func equip(_ weapon: LibraryWeapon, style: WeaponStyle) {
        // She always carries it the spear way (Zaahen's idle and run fit her); Q takes the style's moves.
        guard let carryURL = weaponLibrary.reference(.spear), let movesURL = weaponLibrary.reference(style) else {
            status = "Choose the skins for the moves first (\(WeaponStyle.spear.defaultFile), \(WeaponStyle.sword.defaultFile))"
            return
        }
        let keepW = spellWeapon?.wFrom
        let dir = championsDir
        busy = true
        status = "Getting \(style.moves)…"
        Task {
            let sources = await Task.detached(operation: { () -> (PortSource, PortSource)? in
                func open(_ url: URL) -> PortSource? {
                    guard let info = try? FantomeInfo.inspect(url, championsDir: dir) else { return nil }
                    return PortSource(modWad: info.modWad, champion: info.champion, skin: info.skins.first ?? 0, label: info.name)
                }
                guard let c = open(carryURL), let m = open(movesURL) else { return nil }
                return (c, m)
            }).value
            guard let (carrySource, movesSource) = sources else {
                self.busy = false
                self.status = "Couldn't read the moves' skins"
                return
            }
            self.busy = false
            self.removeExtraWeapon()
            self.addWeapon(from: carrySource, part: WeaponStyle.spear.part, carry: true) { [self] in
                guard let placed = self.swapExtraWeapon(to: weapon, style: style) else {
                    self.status = "Couldn't fit \(weapon.name) in her hand"
                    return
                }
                Task {
                    // Sword moves: for Q the sword moves to the grip the Ayaka skin has on her katana.
                    var regrip: Regrip?
                    if style == .sword { regrip = await self.swordGrip(placed: placed, from: movesSource) }
                    let clips = await self.sourceClips(from: movesSource)
                    func pick(_ l: String) -> ClipInfo? { clips.first { $0.label.lowercased() == l.lowercased() } }
                    self.setUpSpellWeapon(part: Self.heldPart, q1: pick(style.q.0), q2: pick(style.q.1), w: nil, wFrom: keepW,
                                          from: movesSource, weaponLocal: regrip) {
                        self.equippedWeapon = (weapon.id, style)
                        self.status = "\(weapon.name) is in her hand with \(style.moves)" + (keepW != nil ? " (W unchanged)" : "")
                            + ": press Q below to preview"
                    }
                }
            }
        }
    }

    /// Where a weapon put in the hand sits: its own frame (handle at 0, blade along +Y) → model space, and how far up from
    /// the handle it's held, at what size.
    struct Placement { var matrix: simd_float4x4; var grip: Float; var scale: Float }

    /// How to hold a carried weapon during `source`'s moves: in the hand `source` holds its weapon (e.g. the Ayaka skin's
    /// katana) with, gripped where that hand closes on it.
    private func swordGrip(placed: Placement, from source: PortSource) async -> Regrip? {
        guard let target, let bone = weaponBone else { return nil }
        let dir = championsDir
        var fitted = target
        fitted.skeleton = bone.skeleton
        let ts = bone.skeleton
        let file = WeaponStyle.sword.part
        let idle = WeaponStyle.sword.carry?.idle ?? []
        return await Task.detached { () -> Regrip? in
            guard let files = try? source.open(championsDir: dir),
                  let skin = try? SkinData.load(files, champion: source.champion, num: source.skin, needSkeleton: true),
                  let ss = skin.skeleton else { return nil }
            let clips = skin.clips(files)
            let grip = idle.lazy.compactMap { n in clips.first { $0.label.lowercased() == n }?.animation(files) }.first
                ?? Self.attackClips(skin, files).first
            guard let grip, let (m, swordHand, _) = WeaponSwap.heldPart(file, source: skin, sourceClips: [grip], target: fitted,
                                                               scale: Retarget.bodyScale(source: ss, target: ts)),
                  let frame = WeaponFrame(m.positions) else { return nil }
            // The katana's frame in the hand, and our weapon put there with its grip where the hand closes on the katana.
            let handPos = ts.joints[swordHand].position
            let at = simd_dot(handPos - frame.handle, frame.axes.long)
            let b = Self.frameMatrix(frame) * Skeleton.trs(SIMD3(0, at - placed.grip * placed.scale, 0), simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)),
                                                          SIMD3(repeating: placed.scale))
            // Vertices sit at `placed` in the bind pose; in the sword hand they should sit at `b`.
            return Regrip(hand: swordHand, offset: ts.joints[swordHand].bind.inverse * b * placed.matrix.inverse * ts.joints[ts.joints.count - 1].bind)
        }.value
    }

    /// A weapon held in another grip for some moves: following `hand`, at `offset` (weapon bone bind → that hand).
    struct Regrip { var hand: Int; var offset: simd_float4x4 }

    nonisolated static func frameMatrix(_ f: WeaponFrame) -> simd_float4x4 {
        simd_float4x4(SIMD4(f.axes.thin, 0), SIMD4(f.axes.long, 0), SIMD4(f.axes.wide, 0), SIMD4(f.handle, 1))
    }

    /// The library weapon in her hand and its style.
    @Published private(set) var equippedWeapon: (id: String, style: WeaponStyle)?

    /// Takes the weapon from another skin out of her hand (model, weapon bone, carry and spell animations).
    private func removeExtraWeapon() {
        guard let ew = extraWeapon, var m = restMesh ?? mesh else { return }
        restMesh = nil
        m = Self.removing(ew.part, from: m)
        playback = nil
        mesh = m
        heldWeapons.removeAll { $0 == ew.part }
        for slot in textures { slot.parts.removeAll { $0 == ew.part } }
        textures.removeAll { $0.parts.isEmpty && ($0.exportPath?.contains("weapon") ?? false) }
        partTexture[ew.part] = nil
        for k in carryClips.keys { clipOverrides[k] = nil }
        if let sw = spellWeapon { for k in sw.clips.keys { clipOverrides[k] = nil } }
        spellWeapon = nil
        carryClips = [:]
        extraWeapon = nil
        weaponBone = nil
        equippedWeapon = nil
        revision += 1
    }

    /// The model without a part (and the points only it used).
    nonisolated static func removing(_ part: String, from m: SkinnedMesh) -> SkinnedMesh {
        var out = SkinnedMesh()
        var map: [Int: UInt16] = [:]
        for p in m.parts where p.name != part {
            let start = out.indices.count
            for k in p.startIndex ..< min(m.indices.count, p.startIndex + p.indexCount) {
                let v = Int(m.indices[k])
                if map[v] == nil {
                    map[v] = UInt16(out.positions.count)
                    out.positions.append(m.positions[v]); out.normals.append(m.normals[v]); out.uvs.append(m.uvs[v])
                    out.boneIndices.append(m.boneIndices[v]); out.weights.append(m.weights[v])
                }
                out.indices.append(map[v]!)
            }
            out.parts.append(.init(name: p.name, startIndex: start, indexCount: out.indices.count - start))
        }
        return out
    }

    /// Replaces the weapon just put in her hand by a library weapon, at the same place: same grip (the same share of its
    /// length from the handle), blade along the same line, flat side the same way.
    private func swapExtraWeapon(to weapon: LibraryWeapon, style: WeaponStyle) -> Placement? {
        guard let ew = extraWeapon, let bone = weaponBone, let champion, let current = restMesh ?? mesh,
              let p = current.parts.first(where: { $0.name == ew.part }), let g = weaponLibrary.geometry(weapon) else { return nil }
        let idx = current.indices[p.startIndex ..< min(current.indices.count, p.startIndex + p.indexCount)].map(Int.init)
        guard let first = idx.first, let frame = WeaponFrame(Array(Set(idx)).map { current.positions[$0] }) else { return nil }
        let hand = bone.skeleton.joints[bone.held.hand].position
        let grip = simd_dot(hand - frame.handle, frame.axes.long)
        let share = min(max(grip / frame.length, 0), 1)
        // Its own size, unless far off the original's.
        let k: Float = weapon.length < 0.4 * frame.length || weapon.length > 2.5 * frame.length ? frame.length / max(weapon.length, 1e-3) : 1
        // Where it's held: a sword by its own handle (the thinnest band near the handle end); a spear like the reference holds
        // its own (or a third of the way up when swung like a sword).
        let own: Float
        if weapon.style == .sword {
            // Thickness of each slice around its own middle (a big guard pulls the overall center line off the grip).
            let bins = 24, top = 0.4 * weapon.length
            var slices = [[SIMD2<Float>]](repeating: [], count: bins)
            for q in g.positions where q.y < top { slices[min(bins - 1, max(0, Int(q.y / top * Float(bins))))].append(SIMD2(q.x, q.z)) }
            func spread(_ pts: [SIMD2<Float>]) -> Float {
                let c = pts.reduce(.zero, +) / Float(pts.count)
                return pts.map { simd_distance($0, c) }.max() ?? 0
            }
            let thinnest = (1 ..< bins).filter { slices[$0].count >= 4 }.min { spread(slices[$0]) < spread(slices[$1]) } ?? 2
            own = (Float(thinnest) + 0.5) / Float(bins) * top
            if ProcessInfo.processInfo.environment["SKINLAB_TEST"] != nil { print("grip of \(weapon.name): \(own) of \(weapon.length)") }
        } else {
            own = (style == .spear ? share : 0.35) * weapon.length
        }
        let shift = grip - own * k
        let bi = current.boneIndices[first], bw = current.weights[first]
        restMesh = nil
        var m = Self.removing(ew.part, from: current)
        let offset = m.positions.count
        guard offset + g.positions.count <= 65535 else { return nil }
        // Swords are carried blade down (the way the spear's butt points), held by the handle; spears like the spear.
        let carriedDown = weapon.style == .sword
        let local = carriedDown
            ? Skeleton.trs(SIMD3(0, grip + own * k, 0), simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)), SIMD3(1, 1, 1)) * simd_float4x4(diagonal: SIMD4(-k, -k, k, 1))
            : Skeleton.trs(SIMD3(0, shift, 0), simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)), SIMD3(repeating: k))
        let placement = Self.frameMatrix(frame) * local
        let turn = simd_float3x3(SIMD3(placement.columns.0.x, placement.columns.0.y, placement.columns.0.z),
                                 SIMD3(placement.columns.1.x, placement.columns.1.y, placement.columns.1.z),
                                 SIMD3(placement.columns.2.x, placement.columns.2.y, placement.columns.2.z))
        for i in g.positions.indices {
            let w = placement * SIMD4(g.positions[i], 1)
            m.positions.append(SIMD3(w.x, w.y, w.z))
            let n = turn * g.normals[i]
            m.normals.append(simd_length(n) > 0 ? simd_normalize(n) : n)
            m.uvs.append(g.uvs[i]); m.boneIndices.append(bi); m.weights.append(bw)
        }
        var name = "Weapon_" + String(weapon.name.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(24))
        if name == "Weapon_" { name += weapon.id.prefix(6) }
        while m.parts.contains(where: { $0.name == name }) { name += "_" }
        m.parts.append(.init(name: name, startIndex: m.indices.count, indexCount: g.indices.count))
        m.indices += g.indices.map { UInt16(Int($0) + offset) }
        for slot in textures { slot.parts.removeAll { $0 == ew.part } }
        textures.removeAll { $0.parts.isEmpty && ($0.exportPath?.contains("weapon") ?? false) }
        partTexture[ew.part] = nil
        if let img = weaponLibrary.texture(weapon) {
            let h = pathHash("skinlab/weapons/\(weapon.id).tex")
            let slot = TextureSlot(id: h, data: TextureFile.newTex(img), image: img, parts: [name])
            slot.exportPath = "assets/characters/\(champion.lowercased())/skins/skinlab/weapon_\(weapon.id).tex"
            textures.append(slot)
            partTexture[name] = h
        }
        playback = nil
        mesh = m
        extraWeapon = (ew.source, name)
        heldWeapons = heldWeapons.map { $0 == ew.part ? name : $0 }
        if !heldWeapons.contains(name) { heldWeapons.append(name) }
        revision += 1
        return Placement(matrix: placement, grip: own, scale: k)
    }

    // MARK: Weapon from another skin

    /// A weapon taken from another skin, always in the champion's hand; that skin also gives the spells' moves.
    @Published private(set) var extraWeapon: (source: PortSource, part: String)?
    /// The weapon bone added to the skeleton for it (in the hand), and the skeleton with it.
    private(set) var weaponBone: (held: WeaponSwap.Held, skeleton: Skeleton)?
    /// Idle and run animations with the arms carrying that weapon (clip name → animation).
    private(set) var carryClips: [UInt32: AnimClip] = [:]
    @Published var showAddWeaponSheet = false
    /// The champion list starts hidden: SkinLab opens on Camille.
    @Published var sidebar: NavigationSplitViewVisibility = .detailOnly
    /// Where spell animations are taken from: the weapon's skin, else the ported skin.
    var animationSource: PortSource? { extraWeapon?.source ?? lastPortSource }

    /// Joints of the arms (clavicle down to the fingers).
    nonisolated static func armJoints(_ sk: Skeleton) -> Set<UInt32> {
        let roles = Porter.roles(sk)
        let tops = sk.joints.indices.filter { [.clavicle, .upperArm].contains(roles[$0]?.role) }
        return Set(sk.joints.indices.filter { j in tops.contains(j) || tops.contains { sk.isAncestor($0, of: j) } }.map { sk.joints[$0].nameHash })
    }

    /// Puts `part` of another skin (e.g. Zaahen's spear) in the champion's hand, held the way that skin holds it, always shown.
    /// With `carry`, the champion's idle and run animations get that skin's arm moves, so she carries it like it does.
    /// `carryClips`: the source's idle, run and fast-run animations to carry it with (else found by name).
    func addWeapon(from source: PortSource, part: String, carry: Bool, carryFrom: (idle: [String], run: [String], fast: [String])? = nil,
                   then done: (() -> Void)? = nil) {
        guard let target, let original = target.skeleton, let tData = target.skeletonData, let mesh, let game = wad,
              let champion else { return }
        let ts = portLegs?.skeleton ?? original
        let legs = portLegs
        let dir = championsDir
        var fitted = target
        fitted.skeleton = ts
        busy = true
        status = "Adding \(part) from \(source.label)…"
        Task {
            do {
                let (held, tex, carryClips, bone, boneSkeleton) = try await Task.detached {
                    () -> (SkinnedMesh, (UInt64, Data, RGBAImage)?, [UInt32: AnimClip], WeaponSwap.Held, Skeleton) in
                    let files = try source.open(championsDir: dir)
                    let skin = try SkinData.load(files, champion: source.champion, num: source.skin, needSkeleton: true)
                    guard let ss = skin.skeleton, let sData = skin.skeletonData else { throw FormatError("\(source.label)'s skeleton couldn't be read") }
                    let sRest = ss.restPoses(sData)
                    let theirs = skin.clips(files)
                    func raw(_ words: [String], avoid: [String]) -> AnimClip? {
                        for w in words {
                            if let c = theirs.first(where: { c in let l = c.label.lowercased(); return l.contains(w) && !avoid.contains { l.contains($0) } }),
                               let a = c.animation(files) {
                                if ProcessInfo.processInfo.environment["SKINLAB_TEST"] != nil { print("carry/grip clip for \(w): \(c.label) \(a.frameCount) frames") }
                                return a
                            }
                        }
                        return nil
                    }
                    let skip = ["to", "in", "homeguard", "var"]
                    let idle = raw(carryFrom?.idle ?? ["idlebase", "idle_base", "idle1", "idle_loop", "idle"], avoid: skip)
                    let slow = raw(carryFrom?.run ?? ["runslow", "run_base", "runbase", "run1", "run"], avoid: skip + ["fast", "haste"])
                    let fast = raw(carryFrom?.fast ?? ["runfast", "run_fast", "runhaste", "run_haste"], avoid: skip) ?? slow
                    // The grip at rest: how it's held standing (its idle), else in its attacks.
                    let gripClips = idle.map { [$0] } ?? (Self.attackClips(skin, files) + Self.spellClips(skin, files))
                    guard var (m, hand, heldInfo) = WeaponSwap.heldPart(part, source: skin, sourceClips: gripClips, target: fitted,
                                                                        scale: Retarget.bodyScale(source: ss, target: ts)) else {
                        throw FormatError("Couldn't find how \(source.label) holds \(part)")
                    }
                    // A weapon bone in that hand: the weapon follows it, and it moves like the source's weapon in borrowed animations.
                    guard let (_, tsW, influence) = ts.appendingJoint(tData, name: "SkinLab_Weapon", parent: hand) else {
                        throw FormatError("Couldn't add a weapon bone to \(champion)'s skeleton")
                    }
                    for i in m.boneIndices.indices { m.boneIndices[i] = SIMD4(UInt8(clamping: influence), 0, 0, 0) }
                    let tex = skin.partTexture[part].flatMap { h in skin.textures[h].map { (h, $0.data, $0.image) } }
                    let tRest = tsW.restPoses(tData)
                    let weaponHash = tsW.joints.last!.nameHash
                    var carryClips: [UInt32: AnimClip] = [:]
                    if carry {
                        let arms = Self.armJoints(ts)
                        for c in target.clips(game) {
                            let l = c.label.lowercased()
                            let isRun = l.hasPrefix("run") && !l.contains("homeguard")
                            let isIdle = l.hasPrefix("idle") || (c.file != nil && l.count == 8 && l.allSatisfy(\.isHexDigit))
                            guard isRun || isIdle, let mine = c.animation(game) else { continue }
                            guard let src = isRun ? (l.contains("fast") || l.contains("haste") ? fast : slow) : idle else { continue }
                            var base = mine
                            if let legs {
                                let (joints, change) = legs.plan.animationChange(original)
                                for h in joints { base.tracks[h] = base.tracks[h]?.map { var p = $0; p.translation = change(h, p.translation); return p } }
                            }
                            let byCycle = isRun && !l.contains("in")
                            let moved = Retarget.clip(src, source: ss, sourceRest: sRest, target: tsW, targetRest: tRest)
                            var clip = SpellMove.blendedWorld(base, joints: arms, from: moved, byCycle: byCycle, skeleton: tsW, rest: tRest)
                            clip.tracks[weaponHash] = WeaponSwap.weaponTrack(heldInfo, frames: clip.frameCount, source: ss,
                                sourceAt: { f in SpellMove.poses(src, ss, rest: sRest, at: SpellMove.otherFrame(f, of: base, in: src, byCycle: byCycle)) },
                                target: tsW, targetAt: { f in tsW.pose(clip, frame: f, rest: tRest) })
                            carryClips[c.name] = clip
                            if ProcessInfo.processInfo.environment["SKINLAB_TEST"] != nil { print("carry clip:", c.label) }
                        }
                    }
                    heldInfo.hand = hand
                    return (m, tex, carryClips, heldInfo, tsW)
                }.value
                var m = self.restMesh ?? mesh
                self.restMesh = nil
                var name = "\(source.champion)_\(part)"
                while m.parts.contains(where: { $0.name == name }) { name += "_" }
                let offset = m.positions.count
                guard offset + held.positions.count <= 65535 else { throw FormatError("The model is too big to add the weapon") }
                m.positions += held.positions; m.normals += held.normals; m.uvs += held.uvs
                m.boneIndices += held.boneIndices; m.weights += held.weights
                m.parts.append(.init(name: name, startIndex: m.indices.count, indexCount: held.indices.count))
                m.indices += held.indices.map { UInt16(Int($0) + offset) }
                var slots = self.textures
                var pt = self.partTexture
                if let (h, data, img) = tex {
                    if let existing = slots.first(where: { $0.id == h }) {
                        existing.parts.append(name)
                    } else {
                        let slot = TextureSlot(id: h, data: data, image: img, parts: [name])
                        let ext = TextureFile.kind(of: data) == .dds ? "dds" : "tex"
                        slot.exportPath = "assets/characters/\(champion.lowercased())/skins/skinlab/\(source.champion.lowercased())_weapon.\(ext)"
                        slots.append(slot)
                    }
                    pt[name] = h
                }
                self.playback = nil
                self.textures = slots
                self.partTexture = pt
                self.mesh = m
                self.extraWeapon = (source, name)
                self.weaponBone = (bone, boneSkeleton)
                if !self.heldWeapons.contains(name) { self.heldWeapons.append(name) }
                if self.portedFrom == nil { self.portedFrom = self.skinName }
                self.carryClips = carryClips
                for (k, clip) in carryClips where self.spellWeapon?.clips[k] == nil { self.clipOverrides[k] = (clip, []) }
                self.busy = false
                self.revision += 1
                self.status = "\(part) from \(source.label) is in her hand"
                    + (carryClips.isEmpty ? "" : ", carried in \(carryClips.count) idle and run animations")
                    + ". Weapon on Spells… now takes its moves from \(source.label)."
                done?()
            } catch {
                self.busy = false
                self.status = "Couldn't add the weapon: \(error.localizedDescription)"
                if ProcessInfo.processInfo.environment["SKINLAB_TEST"] != nil { print(self.status) }
            }
        }
    }

    /// A weapon of the ported skin held in the right hand for some spells: the replaced animations, and the
    /// show/hide events that draw it and put it away.
    struct SpellWeapon {
        let part: String
        var clips: [UInt32: AnimClip] = [:]
        var events: [UInt32: [GraphEdit.PartEvent]] = [:]
        /// The source animations picked for Q, Q2 and W (to show them again in the sheet).
        var picks: (q1: UInt32?, q2: UInt32?, w: UInt32?) = (nil, nil, nil)
        /// When W's borrowed swing passes in front of the champion, in seconds.
        var wHit: Float?
        /// Another skin whose own W is used.
        var wFrom: PortSource?
    }

    /// The source skin's animations (for picking the spells' moves), one per animation file.
    func sourceClips(from: PortSource? = nil) async -> [ClipInfo] {
        guard let spec = from ?? animationSource else { return [] }
        let dir = championsDir
        return await Task.detached { () -> [ClipInfo] in
            guard let files = try? spec.open(championsDir: dir),
                  let data = try? SkinData.load(files, champion: spec.champion, num: spec.skin) else { return [] }
            var seen = Set<UInt64>()
            let simple = data.clips(files).filter { c in c.file.map { seen.insert($0).inserted } ?? false }
            // Sequences (several pieces, like Yone's Q) that aren't just one listed clip
            var seenSequences = Set<[UInt64]>()
            let joined = data.sequences(files).filter { $0.sequence.count > 1 && seenSequences.insert($0.sequence).inserted }
            return joined + simple
        }.value
    }

    /// The part of the source model that `part` (a part of the ported model) came from.
    nonisolated static func sourcePart(_ part: String, in mesh: SkinnedMesh) -> String {
        mesh.parts.contains { $0.name == part } ? part : (mesh.parts.first { part.hasSuffix("_" + $0.name) }?.name ?? part)
    }

    /// The source animation that looks most like a slash from left to right with `part` (W's suggestion).
    func suggestedSlash(part: String, among clips: [ClipInfo]) async -> UInt32? {
        guard let spec = animationSource else { return nil }
        let dir = championsDir
        return await Task.detached { () -> UInt32? in
            guard let files = try? spec.open(championsDir: dir),
                  let source = try? SkinData.load(files, champion: spec.champion, num: spec.skin, needSkeleton: true),
                  let sk = source.skeleton, let data = source.skeletonData else { return nil }
            let rest = sk.restPoses(data)
            let sourcePart = Self.sourcePart(part, in: source.mesh)
            let height = source.mesh.positions.map(\.y).max() ?? 200
            let skip = ["idle", "run", "walk", "dance", "recall", "death", "taunt", "joke", "laugh", "channel", "sheath", "spawn", "homeguard"]
            var best: (name: UInt32, score: Float)?
            for c in clips where !skip.contains(where: { c.label.lowercased().contains($0) }) {
                guard let h = c.file, let d = files.data(h), let clip = try? AnimClip.decode(d),
                      let path = SpellMove.path(clip, source: source, part: sourcePart, rest: rest),
                      let score = SpellMove.leftToRightScore(path, height: height) else { continue }
                if score > best?.score ?? -.greatestFiniteMagnitude { best = (c.name, score) }
            }
            return best?.name
        }.value
    }

    /// Puts `part` (a weapon of the ported skin) in the right hand for the spells given an animation of the source skin.
    /// Q: drawn with Q1, kept while Q is up, put away after Q2. W: drawn for W, its swing held back so the blade passes
    /// in front of the champion right when W hits (W's own timing), then put away.
    /// `wFrom`: another skin of this champion whose own W is used instead (e.g. a custom skin with its own W).
    /// `from`: the skin the moves come from (else the weapon's or the ported skin); `weaponLocal`: the weapon bone's pose
    /// relative to the hand during Q (a different grip than when carried).
    func setUpSpellWeapon(part: String, q1: ClipInfo?, q2: ClipInfo?, w: ClipInfo?, wFrom: PortSource? = nil, from: PortSource? = nil,
                          weaponLocal: Regrip? = nil, then done: (() -> Void)? = nil) {
        guard q1 != nil || q2 != nil || w != nil || wFrom != nil else { return }
        guard let spec = from ?? animationSource, let target, let original = target.skeleton, let tData = target.skeletonData, let mesh,
              let game = wad else { return }
        let ts = weaponBone?.skeleton ?? portLegs?.skeleton ?? original
        let legs = portLegs
        let dir = championsDir
        let championName = champion ?? "The champion"
        // Moves from the weapon's own skin also move the weapon bone like that skin moves its weapon.
        let bone = extraWeapon.map { $0.source.modWad == spec.modWad && $0.source.champion == spec.champion } == true ? weaponBone?.held : nil
        // Weapons the port already put in the hands: only the animations change, nothing is shown or hidden.
        let inHands = part == Self.heldPart
        var handWeapon = SkinnedMesh()
        if inHands, let ew = extraWeapon, let m = restMesh ?? self.mesh, let p = m.parts.first(where: { $0.name == ew.part }) {
            for i in m.indices[p.startIndex ..< min(m.indices.count, p.startIndex + p.indexCount)] {
                let v = Int(i)
                handWeapon.positions.append(m.positions[v]); handWeapon.normals.append(m.normals[v]); handWeapon.uvs.append(m.uvs[v])
                handWeapon.boneIndices.append(m.boneIndices[v]); handWeapon.weights.append(m.weights[v])
            }
        } else if inHands, let hand = Porter.roles(ts).firstIndex(where: { $0 == Porter.RoleInfo(role: .hand, side: "r") }),
           let inf = ts.influences.firstIndex(of: hand) {
            let m = restMesh ?? mesh
            for v in m.positions.indices where Int(m.boneIndices[v][0]) == inf && m.weights[v][0] > 0.999 {
                handWeapon.positions.append(m.positions[v]); handWeapon.normals.append(m.normals[v]); handWeapon.uvs.append(m.uvs[v])
                handWeapon.boneIndices.append(m.boneIndices[v]); handWeapon.weights.append(m.weights[v])
            }
        }
        busy = true
        status = "Setting up \(part)…"
        Task {
            do {
                let (held, weapon) = try await Task.detached { () -> (SkinnedMesh, SpellWeapon) in
                    let files = try spec.open(championsDir: dir)
                    let source = try SkinData.load(files, champion: spec.champion, num: spec.skin, needSkeleton: true)
                    guard let ss = source.skeleton, let sData = source.skeletonData else { throw FormatError("The source skeleton couldn't be read") }
                    let sRest = ss.restPoses(sData), tRest = ts.restPoses(tData)
                    func clip(_ c: ClipInfo) throws -> AnimClip {
                        guard let a = c.animation(files) else { throw FormatError("\(c.label): animation file not found") }
                        return a
                    }
                    func moved(_ c: ClipInfo) throws -> AnimClip {
                        let src = try clip(c)
                        var r = Retarget.clip(src, source: ss, sourceRest: sRest, target: ts, targetRest: tRest)
                        if let bone, let weapon = ts.joints.last?.nameHash {
                            let result = r
                            r.tracks[weapon] = WeaponSwap.weaponTrack(bone, frames: r.frameCount, source: ss,
                                                                      sourceAt: { f in ss.pose(src, frame: f, rest: sRest) },
                                                                      target: ts, targetAt: { f in ts.pose(result, frame: f, rest: tRest) })
                        }
                        return r
                    }
                    // The grip comes from a picked animation of the ported skin (or one of its attacks).
                    let sourceClips = source.clips(files)
                    guard let gripInfo = q1 ?? w ?? q2 ?? sourceClips.first(where: { $0.label.lowercased().hasPrefix("attack") && $0.file != nil })
                        ?? sourceClips.first(where: { $0.file != nil }) else { throw FormatError("The ported skin has no animations") }
                    let held: SkinnedMesh
                    if inHands {
                        held = handWeapon
                    } else if let h = Retarget.holdInHand(part: Self.sourcePart(part, in: source.mesh), source: source, clip: try clip(gripInfo),
                                                          sourceRest: sRest, target: ts, targetRest: tRest,
                                                          scale: Retarget.bodyScale(source: ss, target: ts)) {
                        held = h
                    } else {
                        throw FormatError("Couldn't find \(part) or a right hand to put it in")
                    }
                    var sw = SpellWeapon(part: part)
                    sw.picks = (q1?.name, q2?.name, wFrom != nil ? UInt32.max : w?.name)
                    sw.wFrom = wFrom
                    let show = GraphEdit.PartEvent(name: "SkinLabWeaponShow", frame: nil, show: [part], hide: [])
                    func hide(at frame: Int? = nil) -> GraphEdit.PartEvent {
                        GraphEdit.PartEvent(name: "SkinLabWeaponHide", frame: frame.map(Float.init), show: [], hide: [part], evenIfCutShort: frame != nil)
                    }
                    // The weapon held differently during Q (a sword swung with a sword grip).
                    // Each frame: the weapon bone (child of the carrying hand) put where the sword hand holds it.
                    func regripped(_ c: AnimClip) -> AnimClip {
                        guard let weaponLocal, let weapon = ts.joints.last, weapon.parent >= 0 else { return c }
                        var c = c
                        var track: [JointPose] = []
                        for f in 0 ..< c.frameCount {
                            let g = ts.globals(ts.pose(c, frame: f, rest: tRest))
                            let m = g[weapon.parent].inverse * g[weaponLocal.hand] * weaponLocal.offset
                            let sx = simd_length(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z))
                            let sy = simd_length(SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z))
                            let sz = simd_length(SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
                            let r = simd_float3x3(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z) / sx, SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z) / sy,
                                                  SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z) / sz)
                            track.append(JointPose(rotation: simd_quatf(r), translation: SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z), scale: SIMD3(sx, sy, sz)))
                        }
                        c.tracks[weapon.nameHash] = track
                        return c
                    }
                    // Q: drawn with Q1, kept while Q is up, put away after Q2.
                    if let q1 {
                        sw.clips[fnv("Spell1")] = regripped(try moved(q1))
                        sw.events[fnv("Spell1")] = [show]
                    }
                    if let q2 {
                        let r2 = regripped(try moved(q2))
                        sw.clips[fnv("Spell1_2")] = r2
                        sw.events[fnv("Spell1_2")] = [show, hide(at: r2.frameCount - 1)]
                    } else if q1 != nil {
                        sw.events[fnv("Spell1_2")] = [hide()]
                    }
                    if q1 != nil || q2 != nil { sw.events[fnv("Spell1_2_to_idle")] = [hide()] }
                    // W: the swing timed to W's hit, in every direction variant of W ("Spell2_0", "Spell2_90"…).
                    if w != nil || wFrom != nil {
                        let own = target.clips(game)
                        let variants = own.compactMap { c -> (ClipInfo, Float)? in
                            guard c.file != nil, let d = SpellMove.direction(of: c.label, spell: "Spell2") else { return nil }
                            return (c, d)
                        }
                        guard let base = variants.min(by: { abs($0.1) < abs($1.1) }), let baseData = base.0.file.flatMap(game.data) else {
                            throw FormatError("\(championName)'s W animation wasn't found")
                        }
                        let ownW = try AnimClip.decode(baseData)
                        let hitAt = SpellMove.impactFrame(ownW, skeleton: original, rest: original.restPoses(tData))
                        var timed: AnimClip
                        if let wFrom {
                            // Another skin's own W (made for this spell): each direction variant moved onto the champion,
                            // its blow nudged onto W's hit.
                            let other = try wFrom.open(championsDir: dir)
                            let skin = try SkinData.load(other, champion: wFrom.champion, num: wFrom.skin, needSkeleton: true)
                            guard let osk = skin.skeleton, let oData = skin.skeletonData else { throw FormatError("\(wFrom.label)'s skeleton couldn't be read") }
                            let oRest = osk.restPoses(oData)
                            let theirs = skin.clips(other)
                            func theirW(_ name: UInt32) -> AnimClip? {
                                guard let f = theirs.first(where: { $0.name == name })?.file, let d = other.data(f), let a = try? AnimClip.decode(d) else { return nil }
                                return Retarget.clip(a, source: osk, sourceRest: oRest, target: ts, targetRest: tRest)
                            }
                            guard let base0 = theirW(base.0.name) else { throw FormatError("\(wFrom.label) has no W animation") }
                            let strike = SpellMove.path(base0, skeleton: ts, rest: tRest, weapon: held)?.strike
                                ?? SpellMove.impactFrame(base0, skeleton: ts, rest: tRest)
                            timed = SpellMove.shifted(base0, strike: strike, hitAt: hitAt)
                            let root = ts.joints[Retarget.bodyRoot(ts)].nameHash
                            // Turned for each direction like the game's own variants (custom skins often reuse one for all).
                            for (c, degrees) in variants {
                                let clip = SpellMove.turned(timed, degrees: degrees - base.1, bodyRoot: root)
                                sw.clips[c.name] = clip
                                sw.events[c.name] = [show, hide(at: clip.frameCount - 1)]
                            }
                        } else if let w {
                            let swing = try moved(w)
                            guard let path = SpellMove.path(swing, skeleton: ts, rest: tRest, weapon: held), path.strike != nil else {
                                throw FormatError("\(w.label) has no swing of \(part) to time")
                            }
                            timed = SpellMove.timed(swing, path: path, hitAt: hitAt, frameCount: ownW.frameCount)
                            if let held = SpellMove.path(timed, skeleton: ts, rest: tRest, weapon: held) {
                                timed = SpellMove.woundUp(timed, path: held, skeleton: ts, rest: tRest, hitAt: hitAt)
                            }
                            let root = ts.joints[Retarget.bodyRoot(ts)].nameHash
                            for (c, degrees) in variants {
                                sw.clips[c.name] = SpellMove.turned(timed, degrees: degrees, bodyRoot: root)
                                sw.events[c.name] = [show, hide(at: timed.frameCount - 1)]
                            }
                        } else { throw FormatError("No W animation picked") }
                        sw.wHit = hitAt / ownW.fps
                        // Back to idle from where the swing ends (instead of the champion's own recovery from its W).
                        let idleInfo = ["idle_loop", "idle1", "idle_base"].lazy
                            .compactMap { n in own.first { $0.label.lowercased() == n && $0.file != nil } }.first
                        if let back = own.first(where: { $0.label.lowercased() == "spell2_to_idle" }),
                           let backClip = back.file.flatMap(game.data).flatMap({ try? AnimClip.decode($0) }),
                           var idle = idleInfo?.file.flatMap(game.data).flatMap({ try? AnimClip.decode($0) }) {
                            if let legs {
                                let (joints, change) = legs.plan.animationChange(original)
                                for h in joints { idle.tracks[h] = idle.tracks[h]?.map { var p = $0; p.translation = change(h, p.translation); return p } }
                            }
                            sw.clips[back.name] = SpellMove.settle(from: SpellMove.frame(timed, timed.frameCount - 1), to: SpellMove.frame(idle, 0),
                                                                   frameCount: backClip.frameCount, fps: timed.fps)
                            sw.events[back.name] = [hide()]
                        }
                    }
                    for clip in ["Recall", "Recall_Return", "Death", "Dance_IN", "Dance_Loop", "Taunt", "Laugh", "Joke"] {
                        sw.events[fnv(clip)] = [hide()]
                    }
                    if inHands { sw.events = [:] }
                    return (held, sw)
                }.value
                if inHands {
                    self.playback = nil
                    self.spellWeapon = weapon
                    self.clipOverrides = weapon.clips.mapValues { ($0, []) }
                    for (k, c) in self.carryClips where self.clipOverrides[k] == nil { self.clipOverrides[k] = (c, []) }
                    self.busy = false
                    self.status = "New animations set up (the weapons stay in her hands): press the buttons below to preview"
                    done?()
                    return
                }
                var m = self.restMesh ?? mesh
                self.restMesh = nil
                m.parts.removeAll { $0.name == part }
                let offset = m.positions.count
                guard offset + held.positions.count <= 65535 else { throw FormatError("The model is too big to add the weapon") }
                m.positions += held.positions
                m.normals += held.normals
                m.uvs += held.uvs
                m.boneIndices += held.boneIndices
                m.weights += held.weights
                m.parts.append(.init(name: part, startIndex: m.indices.count, indexCount: held.indices.count))
                m.indices += held.indices.map { UInt16(Int($0) + offset) }
                self.playback = nil
                self.mesh = m
                if !self.portHide.contains(part) { self.portHide.append(part) }    // hidden until a spell draws it, but kept in the skin
                self.hiddenParts.insert(part)
                self.spellWeapon = weapon
                self.clipOverrides = weapon.clips.mapValues { clip in
                    (clip, [])
                }
                for (k, c) in self.carryClips where self.clipOverrides[k] == nil { self.clipOverrides[k] = (c, []) }
                for (name, list) in weapon.events where weapon.clips[name] != nil {
                    self.clipOverrides[name]?.events = list.map { PartEvent(frame: $0.frame ?? 0, show: $0.show, hide: $0.hide) }
                }
                self.busy = false
                var spells: [String] = []
                if q1 != nil || q2 != nil { spells.append("Q") }
                if let hit = weapon.wHit { spells.append(String(format: "W (its swing lands at %.2f s, when W hits)", hit)) }
                self.status = "\(part) is drawn on " + spells.joined(separator: " and ") + ": press the buttons below to preview"
                done?()
            } catch {
                self.busy = false
                self.status = "Couldn't set up the weapon: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Animation preview

    /// The skeleton the shown model is bound to, with its rest pose.
    var animSkeleton: (Skeleton, [JointPose])? {
        guard let target, let data = target.skeletonData, let sk = weaponBone?.skeleton ?? portLegs?.skeleton ?? target.skeleton else { return nil }
        return (sk, sk.restPoses(data))
    }

    /// Buttons for the main animations: Q W E R, attack, idle, run, recall, dance.
    var quickClips: [(title: String, clip: ClipInfo)] {
        func find(_ names: [String]) -> ClipInfo? {
            for n in names { if let c = clipList.first(where: { $0.label.lowercased() == n.lowercased() }) { return c } }
            return nil
        }
        let wanted: [(String, [String])] = [
            ("Idle", ["Idle1", "Idle_Base", "Idle_Loop", "Idle2"]), ("Run", ["Run_Base", "Run", "Run2", "Run_Fast"]),
            ("Attack", ["Attack1", "Attack2"]), ("Q", ["Spell1", "Spell1A"]), ("Q2", ["Spell1_2", "Spell1B"]),
            ("W", ["Spell2", "Spell2_0", "Spell2A"]), ("E", ["Spell3", "Spell3_Dash1", "Spell3_0"]), ("R", ["Spell4", "Spell4_IN"]),
            ("Recall", ["Recall"]), ("Dance", ["Dance_Loop", "Dance", "Dance_IN"]),
        ]
        return wanted.compactMap { title, names in find(names).map { (title, $0) } }
    }

    func play(_ info: ClipInfo) {
        guard let target, let wad else { return }
        let names = Dictionary(mesh?.parts.map { (fnv($0.name), $0.name) } ?? [], uniquingKeysWith: { a, _ in a })
        func events(_ e: [(frame: Float, show: [UInt32], hide: [UInt32])]) -> [PartEvent] {
            e.map { PartEvent(frame: $0.frame, show: $0.show.compactMap { names[$0] }, hide: $0.hide.compactMap { names[$0] }) }
                .sorted { $0.frame < $1.frame }
        }
        if let o = clipOverrides[info.name] {
            playback = Playback(label: info.label, clip: o.clip, events: o.events, loop: loopPlayback, started: Date())
            return
        }
        guard let file = info.file, let data = wad.data(file) else {
            status = "\(info.label): animation file not found"
            return
        }
        do {
            var clip = try AnimClip.decode(data)
            if let legs = portLegs, let original = target.skeleton {
                let (joints, change) = legs.plan.animationChange(original)
                for h in joints { clip.tracks[h] = clip.tracks[h]?.map { var p = $0; p.translation = change(h, p.translation); return p } }
            }
            playback = Playback(label: info.label, clip: clip, events: events(info.partEvents), loop: loopPlayback, started: Date())
            status = String(format: "Playing %@ (%.1f s)", info.label, clip.duration)
        } catch {
            status = "Couldn't play \(info.label): \(error.localizedDescription)"
        }
    }

    func stopPlayback() { playback = nil }

    /// Debug: the current model posed (on the CPU) by a replaced clip, with the weapon shown.
    func previewOverridePose(clip label: String, at fraction: Float) {
        guard let o = clipOverrides[fnv(label)], let (sk, rest) = animSkeleton, let mesh else { print("no override \(label)"); return }
        let frame = Int(Float(o.clip.frameCount - 1) * fraction)
        let g = sk.globals(sk.pose(o.clip, frame: frame, rest: rest))
        if restMesh == nil { restMesh = mesh }
        self.mesh = (restMesh ?? mesh).posed(sk, globals: g)
        if let w = spellWeapon { hiddenParts.remove(w.part) }
        revision += 1
        print("override \(label): frame \(frame) of \(o.clip.frameCount)")
    }

    /// Debug/preview: shows the current skin posed at a moment of one of its animations.
    func previewPose(clip label: String, at fraction: Float) {
        guard let target, let wad, let sk = target.skeleton, let sklData = target.skeletonData, let mesh else { return }
        guard let info = target.clips(wad).first(where: { $0.label.lowercased() == label.lowercased() }), let file = info.file,
              let data = wad.data(file) else { status = "No clip \(label)"; return }
        do {
            let clip = try AnimClip.decode(data)
            let frame = Int(Float(clip.frameCount - 1) * fraction)
            let g = sk.globals(sk.pose(clip, frame: frame, rest: sk.restPoses(sklData)))
            if restMesh == nil { restMesh = mesh }
            self.mesh = (restMesh ?? mesh).posed(sk, globals: g)
            revision += 1
            status = "\(label): frame \(frame) of \(clip.frameCount), \(clip.tracks.count) joints animated"
            print(status)
        } catch {
            status = "Couldn't read \(label): \(error.localizedDescription)"
            print(status)
        }
    }

    /// One brush dab on a model part at texture coordinates `uv`; `radius` in texture units (fraction of the width).
    func paint(part: String, uv: SIMD2<Float>, radius: Float, beginStroke: Bool) {
        guard let h = partTexture[part], let slot = textures.first(where: { $0.id == h }) else { return }
        let layer = slot.paintLayer()
        let (w, hgt) = slot.size
        let fx = uv.x - uv.x.rounded(.down), fy = uv.y - uv.y.rounded(.down)
        let x = fx * Float(w), y = fy * Float(hgt)
        if paintTool == .pick {
            let i = (min(Int(y), hgt - 1) * w + min(Int(x), w - 1)) * 4
            if i + 2 < slot.shownRGBA.count {
                paintColor = CGColor(srgbRed: CGFloat(slot.shownRGBA[i]) / 255, green: CGFloat(slot.shownRGBA[i + 1]) / 255,
                                     blue: CGFloat(slot.shownRGBA[i + 2]) / 255, alpha: 1)
            }
            return
        }
        if beginStroke { layer.beginStroke() }
        let c = paintColor.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components ?? [1, 1, 1, 1]
        layer.dab(tool: paintTool, x: x, y: y, radius: max(radius * Float(w), 1), strength: Float(brushStrength),
                  color: (Float(c[0]), Float(c.count > 2 ? c[1] : c[0]), Float(c.count > 2 ? c[2] : c[0])),
                  under: slot.baseRGBA, shown: slot.shownRGBA)
        slot.repaint()
        lastPainted = slot
        revision += 1
    }

    func undoPaint() {
        guard let slot = lastPainted, let layer = slot.paint, layer.canUndo else { return }
        layer.undoStroke()
        slot.repaint()
        revision += 1
    }

    func clearPaint() {
        for slot in textures where slot.paint != nil { slot.paint?.clear(); slot.repaint() }
        revision += 1
    }

    func changed(_ slot: TextureSlot) {
        slot.render()
        revision += 1
    }

    // MARK: Export

    /// Writes a .fantome with only the textures you changed, ready to import in Zushi.
    func exportFantome(preview: NSImage?, to fixedDest: URL? = nil) {
        guard let champion else { return }
        let leftOut = portedFrom == nil ? [] : hiddenParts.subtracting(portHide)
        let files = textures.filter { slot in slot.parts.contains { !leftOut.contains($0) } }.compactMap { $0.modFile() }
        guard !files.isEmpty || portedFrom != nil || !vfxPicks.isEmpty else { status = "Change a texture first"; return }
        let name = modName.trimmingCharacters(in: .whitespaces).isEmpty ? "My \(champion) skin" : modName
        var dest: URL
        if let fixedDest {
            dest = fixedDest
        } else {
            let panel = NSSavePanel()
            panel.title = "Save Custom Skin"
            panel.nameFieldStringValue = name.replacingOccurrences(of: "/", with: "-") + ".fantome"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            dest = url
        }
        if dest.pathExtension.lowercased() != "fantome" { dest.appendPathExtension("fantome") }

        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("SkinLab-\(UUID().uuidString)")
        do {
            let wadDir = tmp.appendingPathComponent("WAD/\(champion).wad.client")
            try fm.createDirectory(at: wadDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: tmp.appendingPathComponent("META"), withIntermediateDirectories: true)
            for f in files {
                try f.data.write(to: wadDir.appendingPathComponent(String(format: "%016llx.%@", f.hash, f.ext)))
            }
            if portedFrom != nil, let target, var mesh = restMesh ?? mesh, let skin {
                // Parts you switched off are left out (parts the skin hides at start stay, the game shows them when needed).
                let dropped = hiddenParts.subtracting(portHide)
                mesh.parts.removeAll { dropped.contains($0.name) }
                mesh = mesh.compacted()
                // The ported model, and this skin's .bin pointing at it and at its textures.
                let sknPath = "ASSETS/Characters/\(champion)/Skins/SkinLab/\(champion)Skin\(skin).skn"
                try mesh.serialized().write(to: wadDir.appendingPathComponent(String(format: "%016llx.skn", pathHash(sknPath))))
                let asText: Bool = { if case .string = target.meshProps["texture"] { return true }; return false }()
                func ref(_ h: UInt64) -> BinValue {
                    if let path = textures.first(where: { $0.id == h })?.exportPath { return asText ? .string(path) : .file(pathHash(path)) }
                    return .file(h)
                }
                var perPart: [String: BinValue] = [:]
                for (part, h) in partTexture where mesh.parts.contains(where: { $0.name == part }) { perPart[part] = ref(h) }
                let firstNew = textures.first { $0.exportPath != nil }.map { ref($0.id) }
                // Shorter legs: the adjusted skeleton, and this skin's animations adjusted the same way (as new files).
                var sklPath: String?
                if portLegs != nil || weaponBone != nil, let original = target.skeleton, let sklData = target.skeletonData {
                    let path = "ASSETS/Characters/\(champion)/Skins/SkinLab/\(champion)Skin\(skin).skl"
                    var file = sklData
                    if let legs = portLegs { file = original.patchedFile(sklData, changedTo: legs.skeleton) }
                    if let bone = weaponBone {
                        // The weapon bone in the hand (the skeleton with shorter legs, if any).
                        guard let added = (portLegs?.skeleton ?? original).appendingJoint(file, name: "SkinLab_Weapon", parent: bone.held.hand) else {
                            throw FormatError("Couldn't add the weapon bone")
                        }
                        file = added.data
                    }
                    try file.write(to: wadDir.appendingPathComponent(String(format: "%016llx.skl", pathHash(path))))
                    sklPath = path
                }
                if portLegs != nil || spellWeapon != nil || !carryClips.isEmpty, let wad, let original = target.skeleton {
                    let clips = (spellWeapon?.clips ?? [:]).merging(carryClips) { spell, _ in spell }
                    let files = try Self.animationFiles(target: target, wad: wad, champion: champion, skin: skin,
                                                        legs: portLegs.map { ($0.plan, original) },
                                                        overrides: clips.mapValues { $0.encoded() },
                                                        events: spellWeapon?.events ?? [:])
                    for (hash, ext, data) in files {
                        try data.write(to: wadDir.appendingPathComponent(String(format: "%016llx.%@", hash, ext)))
                    }
                }
                // Weapon swap: the thrown weapons of the spells (same files, so the effects show the new weapon).
                if let part = swappedParts.first, let slot = textures.first(where: { $0.id == partTexture[part] }), let image = slot.edited,
                   let rgba = RGBAImage(cgImage: image, width: slot.original.width, height: slot.original.height) {
                    for tw in thrownWeapons {
                        guard let scb = tw.replacement(mesh, parts: swappedParts) else { continue }
                        let tex = TextureFile.encode(rgba, like: tw.originalTexture)
                        try scb.write(to: wadDir.appendingPathComponent(String(format: "%016llx.scb", pathHash(tw.meshPath))))
                        let ext = tw.texturePath.lowercased().hasSuffix(".dds") ? "dds" : "tex"
                        try tex.write(to: wadDir.appendingPathComponent(String(format: "%016llx.%@", pathHash(tw.texturePath), ext)))
                    }
                }
                let bin = Porter.editedBin(target: target, sknPath: sknPath, sklPath: sklPath, sizeFactor: sklPath == nil ? 1 : sizeFactor,
                                           partTexturePath: perPart,
                                           defaultTexture: firstNew ?? perPart.values.first, hide: portHide)
                var binData = bin
                if !vfxPicks.isEmpty, let wad {
                    binData = try VfxSwap.apply(try BinFile.parse(bin), files: wad, champion: champion, picks: vfxPicks).serialized()
                }
                try binData.write(to: wadDir.appendingPathComponent(String(format: "%016llx.bin", SkinData.binHash(champion, skin))))
            } else if !vfxPicks.isEmpty, let target, let skin, let wad {
                // Not ported: only the effects change.
                try VfxSwap.apply(target.bin, files: wad, champion: champion, picks: vfxPicks).serialized()
                    .write(to: wadDir.appendingPathComponent(String(format: "%016llx.bin", SkinData.binHash(champion, skin))))
            }
            let info: [String: String] = [
                "Name": name, "Author": modAuthor.isEmpty ? "Unknown" : modAuthor, "Version": "1.0.0",
                "Description": portedFrom.map { "\($0) ported with SkinLab" } ?? "Made with SkinLab",
            ]
            try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys])
                .write(to: tmp.appendingPathComponent("META/info.json"))
            if let preview, let tiff = preview.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try png.write(to: tmp.appendingPathComponent("META/image.png"))
            }
            try? fm.removeItem(at: dest)
            let zip = Process()
            zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            zip.currentDirectoryURL = tmp
            zip.arguments = ["-r", "-X", "-q", dest.path, "META", "WAD"]
            try zip.run()
            zip.waitUntilExit()
            try? fm.removeItem(at: tmp)
            guard zip.terminationStatus == 0 else { throw FormatError("zip failed") }
            status = "Saved \(dest.lastPathComponent). Import it in Zushi's Customs tab."
            if fixedDest == nil { NSWorkspace.shared.activateFileViewerSelecting([dest]) }
        } catch {
            try? fm.removeItem(at: tmp)
            status = "Couldn't save: \(error.localizedDescription)"
        }
    }
}
