import Foundation

// MARK: - Hashes

/// WAD entry name: XXH64 of the lowercased path.
func pathHash(_ path: String) -> UInt64 {
    let bytes = Array(path.lowercased().utf8)
    return bytes.withUnsafeBufferPointer { sl_xxh64($0.baseAddress, $0.count) }
}

/// .bin field / class / object name: FNV-1a 32 of the lowercased name.
func fnv(_ name: String) -> UInt32 {
    var h: UInt32 = 0x811C_9DC5
    for b in name.lowercased().utf8 {
        h ^= UInt32(b)
        h = h &* 0x0100_0193
    }
    return h
}

struct FormatError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Little-endian reader

struct ByteReader {
    let data: Data
    var pos: Int

    init(_ data: Data, at pos: Int = 0) {
        self.data = data
        self.pos = pos
    }

    var remaining: Int { data.count - pos }

    mutating func need(_ n: Int) throws {
        if n < 0 || remaining < n { throw FormatError("File is truncated") }
    }

    mutating func num<T: FixedWidthInteger>(_: T.Type = T.self) throws -> T {
        try need(MemoryLayout<T>.size)
        var v: T = 0
        _ = withUnsafeMutableBytes(of: &v) { dst in
            data.copyBytes(to: dst, from: data.startIndex + pos ..< data.startIndex + pos + MemoryLayout<T>.size)
        }
        pos += MemoryLayout<T>.size
        return T(littleEndian: v)
    }

    mutating func float() throws -> Float { Float(bitPattern: try num(UInt32.self)) }

    mutating func bytes(_ n: Int) throws -> Data {
        try need(n)
        let d = data.subdata(in: data.startIndex + pos ..< data.startIndex + pos + n)
        pos += n
        return d
    }

    mutating func skip(_ n: Int) throws {
        try need(n)
        pos += n
    }
}

// MARK: - WAD archives (RW v3)

final class Wad {
    struct Entry {
        let offset: Int
        let size: Int
        let decompressedSize: Int
        let type: UInt8
    }

    let url: URL
    private let data: Data
    private(set) var entries: [UInt64: Entry] = [:]

    init(url: URL) throws {
        self.url = url
        data = try Data(contentsOf: url, options: .alwaysMapped)
        var r = ByteReader(data)
        guard try r.bytes(2) == Data("RW".utf8) else { throw FormatError("\(url.lastPathComponent) isn't a WAD file") }
        let major: UInt8 = try r.num()
        _ = try r.num(UInt8.self)
        guard major == 3 else { throw FormatError("Unsupported WAD version \(major)") }
        r.pos = 268
        let count = Int(try r.num(UInt32.self))
        r.pos = 272
        for _ in 0 ..< count {
            let name: UInt64 = try r.num()
            let offset = Int(try r.num(UInt32.self))
            let size = Int(try r.num(UInt32.self))
            let usize = Int(try r.num(UInt32.self))
            let type = try r.num(UInt8.self) & 0x0F
            try r.skip(11)
            entries[name] = Entry(offset: offset, size: size, decompressedSize: usize, type: type)
        }
    }

    func contains(_ hash: UInt64) -> Bool { entries[hash] != nil }

    func read(_ hash: UInt64) throws -> Data {
        guard let e = entries[hash] else { throw FormatError(String(format: "Missing file %016llx", hash)) }
        guard e.offset >= 0, e.offset + e.size <= data.count else { throw FormatError("Corrupt WAD entry") }
        let raw = data.subdata(in: e.offset ..< e.offset + e.size)
        switch e.type {
        case 0:
            return raw
        case 3:
            return try zstd(raw, size: e.decompressedSize)
        case 4:
            // Several subchunks: some stored raw before the first zstd frame (same as cslol's "zstd hack").
            let magic: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD]
            let bytes = [UInt8](raw)
            var start = 0
            while start + 4 <= bytes.count, Array(bytes[start ..< start + 4]) != magic { start += 1 }
            if start + 4 > bytes.count { return raw }
            var out = Data(bytes[0 ..< start])
            out.append(try zstd(Data(bytes[start...]), size: e.decompressedSize - start))
            return out
        default:
            throw FormatError("Unsupported WAD entry type \(e.type)")
        }
    }

    private func zstd(_ src: Data, size: Int) throws -> Data {
        var out = Data(count: size)
        let n = out.withUnsafeMutableBytes { dst in
            src.withUnsafeBytes { s in sl_zstd_decompress(dst.baseAddress, size, s.baseAddress, src.count) }
        }
        guard n >= 0 else { throw FormatError("Couldn't decompress a file") }   // SIZE_MAX comes through as -1
        out.count = n
        return out
    }
}

// MARK: - .bin property files (PROP)

indirect enum BinValue {
    case raw(UInt8, Data)
    case string(String)
    case hash(UInt32)
    case file(UInt64)
    case link(UInt32)
    case list(kind: UInt8, elem: UInt8, [BinValue])
    case embed(kind: UInt8, cls: UInt32, fields: [BinField])
    case option(elem: UInt8, BinValue?)
    case map(key: UInt8, val: UInt8, [(BinValue, BinValue)])

    var typeByte: UInt8 {
        switch self {
        case let .raw(t, _): return t
        case .string: return 0x10
        case .hash: return 0x11
        case .file: return 0x12
        case .link: return 0x84
        case let .list(kind, _, _): return kind
        case let .embed(kind, _, _): return kind
        case .option: return 0x85
        case .map: return 0x86
        }
    }

    /// A field of an embedded/pointer struct.
    subscript(_ name: String) -> BinValue? {
        if case let .embed(_, _, fields) = self { return fields.first { $0.name == fnv(name) }?.value }
        return nil
    }

    /// Copy of this struct with a field replaced, added, or (nil) removed.
    func setting(_ name: String, _ value: BinValue?) -> BinValue {
        guard case let .embed(kind, cls, fields) = self else { return self }
        var f = fields.filter { $0.name != fnv(name) }
        if let value {
            if let i = fields.firstIndex(where: { $0.name == fnv(name) }) {
                f.insert(BinField(name: fnv(name), value: value), at: min(i, f.count))
            } else {
                f.append(BinField(name: fnv(name), value: value))
            }
        }
        return .embed(kind: kind, cls: cls, fields: f)
    }

    var items: [BinValue] {
        switch self {
        case let .list(_, _, v): return v
        case let .option(_, v): return v.map { [$0] } ?? []
        default: return []
        }
    }

    var string: String? { if case let .string(s) = self { return s }; return nil }
    var link: UInt32? { if case let .link(l) = self { return l }; return nil }

    /// A path to a game file, stored as text (older) or as its 64-bit hash (newer).
    var fileHash: UInt64? {
        switch self {
        case let .string(s): return s.isEmpty ? nil : pathHash(s)
        case let .file(h): return h == 0 ? nil : h
        default: return nil
        }
    }

    /// This value with nested values replaced where `f` returns one.
    func mapped(_ f: (BinValue) -> BinValue?) -> BinValue {
        if let r = f(self) { return r }
        switch self {
        case let .list(k, e, items): return .list(kind: k, elem: e, items.map { $0.mapped(f) })
        case let .embed(k, c, fields): return .embed(kind: k, cls: c, fields: fields.map { BinField(name: $0.name, value: $0.value.mapped(f)) })
        case let .option(e, v): return .option(elem: e, v?.mapped(f))
        case let .map(k, v, kv): return .map(key: k, val: v, kv.map { ($0.0.mapped(f), $0.1.mapped(f)) })
        default: return self
        }
    }

    /// Every value nested anywhere inside this one (including itself).
    func walk(_ visit: (BinValue) -> Void) {
        visit(self)
        switch self {
        case let .list(_, _, v): v.forEach { $0.walk(visit) }
        case let .embed(_, _, f): f.forEach { $0.value.walk(visit) }
        case let .option(_, v): v?.walk(visit)
        case let .map(_, _, kv): kv.forEach { $0.0.walk(visit); $0.1.walk(visit) }
        default: break
        }
    }
}

struct BinField {
    let name: UInt32
    let value: BinValue
}

struct BinObject {
    let cls: UInt32
    let path: UInt32
    var fields: [BinField]

    subscript(_ name: String) -> BinValue? {
        get { fields.first { $0.name == fnv(name) }?.value }
        set {
            let h = fnv(name)
            if let newValue {
                if let i = fields.firstIndex(where: { $0.name == h }) { fields[i] = BinField(name: h, value: newValue) }
                else { fields.append(BinField(name: h, value: newValue)) }
            } else {
                fields.removeAll { $0.name == h }
            }
        }
    }
}

/// A whole .bin file, kept complete so it can be written back unchanged apart from your edits.
struct BinFile {
    var version: UInt32 = 3
    var links: [String] = []
    var objects: [BinObject] = []
    var tail = Data()

    static func parse(_ data: Data) throws -> BinFile {
        var r = ByteReader(data)
        guard try r.bytes(4) == Data("PROP".utf8) else { throw FormatError("Not a .bin property file") }
        var file = BinFile()
        file.version = try r.num()
        if file.version >= 2 {
            let n = Int(try r.num(UInt32.self))
            for _ in 0 ..< n { file.links.append(String(decoding: try r.bytes(Int(try r.num(UInt16.self))), as: UTF8.self)) }
        }
        let count = Int(try r.num(UInt32.self))
        var classes: [UInt32] = []
        for _ in 0 ..< count { classes.append(try r.num()) }
        for cls in classes {
            let size = Int(try r.num(UInt32.self))
            try r.need(size)
            let end = r.pos + size
            let path: UInt32 = try r.num()
            let fields = try Bin.readFields(&r)
            guard r.pos == end else { throw FormatError("Object size mismatch in .bin") }
            file.objects.append(BinObject(cls: cls, path: path, fields: fields))
        }
        file.tail = try r.bytes(r.remaining)
        return file
    }

    func serialized() -> Data {
        var w = BinWriter()
        w.out.append(contentsOf: Array("PROP".utf8))
        w.num(version)
        if version >= 2 {
            w.num(UInt32(links.count))
            for l in links { w.string(l) }
        }
        w.num(UInt32(objects.count))
        for o in objects { w.num(o.cls) }
        for o in objects {
            let slot = w.sizeSlot()
            w.num(o.path)
            w.fields(o.fields)
            w.fillSize(slot)
        }
        w.out.append(tail)
        return w.out
    }
}

struct BinWriter {
    var out = Data()

    mutating func num<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }

    mutating func string(_ s: String) {
        let b = Array(s.utf8)
        num(UInt16(b.count))
        out.append(contentsOf: b)
    }

    mutating func sizeSlot() -> Int {
        num(UInt32(0))
        return out.count - 4
    }

    mutating func fillSize(_ slot: Int) {
        let size = UInt32(out.count - slot - 4).littleEndian
        withUnsafeBytes(of: size) { out.replaceSubrange(slot ..< slot + 4, with: $0) }
    }

    mutating func fields(_ fields: [BinField]) {
        num(UInt16(fields.count))
        for f in fields {
            num(f.name)
            num(f.value.typeByte)
            value(f.value)
        }
    }

    mutating func value(_ v: BinValue) {
        switch v {
        case let .raw(_, d): out.append(d)
        case let .string(s): string(s)
        case let .hash(h): num(h)
        case let .link(l): num(l)
        case let .file(f): num(f)
        case let .list(_, elem, items):
            num(elem)
            let slot = sizeSlot()
            num(UInt32(items.count))
            items.forEach { value($0) }
            fillSize(slot)
        case let .embed(_, cls, fields):
            num(cls)
            if cls != 0 {
                let slot = sizeSlot()
                self.fields(fields)
                fillSize(slot)
            }
        case let .option(elem, inner):
            num(elem)
            num(UInt8(inner == nil ? 0 : 1))
            if let inner { value(inner) }
        case let .map(key, val, kv):
            num(key)
            num(val)
            let slot = sizeSlot()
            num(UInt32(kv.count))
            for (k, v) in kv { value(k); value(v) }
            fillSize(slot)
        }
    }
}

enum Bin {
    static func parse(_ data: Data) throws -> [BinObject] { try BinFile.parse(data).objects }

    static func readFields(_ r: inout ByteReader) throws -> [BinField] {
        let n = Int(try r.num(UInt16.self))
        var fields: [BinField] = []
        for _ in 0 ..< n {
            let name: UInt32 = try r.num()
            let type: UInt8 = try r.num()
            fields.append(BinField(name: name, value: try readValue(&r, type)))
        }
        return fields
    }

    private static func rawSize(_ type: UInt8) -> Int {
        switch type {
        case 1, 2, 3, 0x87: return 1
        case 4, 5: return 2
        case 6, 7, 10, 15: return 4
        case 8, 9, 11: return 8
        case 12: return 12
        case 13: return 16
        case 14: return 64
        default: return 0
        }
    }

    private static func readValue(_ r: inout ByteReader, _ type: UInt8) throws -> BinValue {
        switch type {
        case 0x10:
            let n = Int(try r.num(UInt16.self))
            return .string(String(decoding: try r.bytes(n), as: UTF8.self))
        case 0x11: return .hash(try r.num())
        case 0x84: return .link(try r.num())
        case 0x12: return .file(try r.num())
        case 0x80, 0x81:
            let elem: UInt8 = try r.num()
            try r.skip(4)
            let n = Int(try r.num(UInt32.self))
            var items: [BinValue] = []
            for _ in 0 ..< n { items.append(try readValue(&r, elem)) }
            return .list(kind: type, elem: elem, items)
        case 0x82, 0x83:
            let cls: UInt32 = try r.num()
            if cls == 0 { return .embed(kind: type, cls: 0, fields: []) }
            try r.skip(4)
            return .embed(kind: type, cls: cls, fields: try readFields(&r))
        case 0x85:
            let elem: UInt8 = try r.num()
            let has: UInt8 = try r.num()
            return .option(elem: elem, has != 0 ? try readValue(&r, elem) : nil)
        case 0x86:
            let key: UInt8 = try r.num()
            let val: UInt8 = try r.num()
            try r.skip(4)
            let n = Int(try r.num(UInt32.self))
            var kv: [(BinValue, BinValue)] = []
            for _ in 0 ..< n { kv.append((try readValue(&r, key), try readValue(&r, val))) }
            return .map(key: key, val: val, kv)
        default:
            let n = rawSize(type)
            guard n > 0 else { throw FormatError(String(format: "Unknown .bin value type 0x%02x", type)) }
            return .raw(type, try r.bytes(n))
        }
    }
}
