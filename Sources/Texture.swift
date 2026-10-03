import Foundation
import CoreGraphics

/// A decoded texture: straight RGBA, 8 bits per channel, top row first.
struct RGBAImage {
    var width: Int
    var height: Int
    var pixels: [UInt8]

    var cgImage: CGImage? {
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Draws any image into straight RGBA at the given size.
    init?(cgImage: CGImage, width: Int, height: Int) {
        var premul = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(data: &premul, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        for i in stride(from: 0, to: premul.count, by: 4) {   // un-premultiply
            let a = Int(premul[i + 3])
            if a > 0 && a < 255 {
                for c in 0 ..< 3 { premul[i + c] = UInt8(min(255, Int(premul[i + c]) * 255 / a)) }
            }
        }
        self.init(width: width, height: height, pixels: premul)
    }

    init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// Half-size copy (for mipmaps).
    func halved() -> RGBAImage {
        let w = max(1, width / 2), h = max(1, height / 2)
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0 ..< h {
            for x in 0 ..< w {
                for c in 0 ..< 4 {
                    var sum = 0
                    for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
                        let sx = min(width - 1, x * 2 + dx), sy = min(height - 1, y * 2 + dy)
                        sum += Int(pixels[(sy * width + sx) * 4 + c])
                    }
                    out[(y * w + x) * 4 + c] = UInt8(sum / 4)
                }
            }
        }
        return RGBAImage(width: w, height: h, pixels: out)
    }
}

/// League texture files: .tex (Riot's container) and .dds.
enum TextureFile {
    enum Kind { case tex, dds }

    static func kind(of data: Data) -> Kind? {
        if data.starts(with: Data("TEX\0".utf8)) { return .tex }
        if data.starts(with: Data("DDS ".utf8)) { return .dds }
        return nil
    }

    private enum Pixels { case bc1, bc3, bgra8 }

    private static func levelSize(_ f: Pixels, _ w: Int, _ h: Int) -> Int {
        switch f {
        case .bc1: return max(1, (w + 3) / 4) * max(1, (h + 3) / 4) * 8
        case .bc3: return max(1, (w + 3) / 4) * max(1, (h + 3) / 4) * 16
        case .bgra8: return w * h * 4
        }
    }

    static func decode(_ data: Data) throws -> RGBAImage {
        var r = ByteReader(data)
        switch kind(of: data) {
        case .tex:
            try r.skip(4)
            let w = Int(try r.num(UInt16.self)), h = Int(try r.num(UInt16.self))
            _ = try r.num(UInt8.self)
            let format: UInt8 = try r.num()
            _ = try r.num(UInt8.self)
            _ = try r.num(UInt8.self)
            let px: Pixels
            switch format {
            case 10, 11: px = .bc1
            case 12: px = .bc3
            case 20: px = .bgra8
            default: throw FormatError("Unsupported .tex format \(format)")
            }
            // With mipmaps the smallest level comes first, so the full-size image is at the end.
            let size = levelSize(px, w, h)
            guard data.count >= 12 + size else { throw FormatError("Texture is truncated") }
            return decodePixels(px, data.subdata(in: data.count - size ..< data.count), w, h)
        case .dds:
            try r.skip(12)
            let h = Int(try r.num(UInt32.self)), w = Int(try r.num(UInt32.self))
            r.pos = 80
            let pfFlags: UInt32 = try r.num()
            let fourCC = String(decoding: try r.bytes(4), as: UTF8.self)
            let bits: UInt32 = try r.num()
            let px: Pixels
            if pfFlags & 0x4 != 0 {
                switch fourCC {
                case "DXT1": px = .bc1
                case "DXT5": px = .bc3
                default: throw FormatError("Unsupported .dds format \(fourCC)")
                }
            } else if bits == 32 {
                px = .bgra8
            } else {
                throw FormatError("Unsupported .dds format")
            }
            let size = levelSize(px, w, h)
            guard data.count >= 128 + size else { throw FormatError("Texture is truncated") }
            return decodePixels(px, data.subdata(in: 128 ..< 128 + size), w, h)
        case nil:
            throw FormatError("Not a texture")
        }
    }

    /// Re-encodes `image` in the same container as `original`, uncompressed, keeping its mipmap setting.
    static func encode(_ image: RGBAImage, like original: Data) -> Data {
        var levels = [image]
        var hasMips = false
        if kind(of: original) == .tex { hasMips = original.count > 11 && original[original.startIndex + 11] & 1 != 0 }
        if kind(of: original) == .dds {
            let count = original.subdata(in: original.startIndex + 28 ..< original.startIndex + 32).withUnsafeBytes { $0.load(as: UInt32.self) }
            hasMips = count > 1
        }
        if hasMips {
            while let last = levels.last, last.width > 1 || last.height > 1 { levels.append(last.halved()) }
        }
        func bgra(_ img: RGBAImage) -> Data {
            var out = [UInt8](repeating: 0, count: img.pixels.count)
            for i in stride(from: 0, to: out.count, by: 4) {
                out[i] = img.pixels[i + 2]; out[i + 1] = img.pixels[i + 1]
                out[i + 2] = img.pixels[i]; out[i + 3] = img.pixels[i + 3]
            }
            return Data(out)
        }
        var out = Data()
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }

        if kind(of: original) == .dds {
            out.append(contentsOf: Array("DDS ".utf8))
            put(UInt32(124))
            put(UInt32(0x1 | 0x2 | 0x4 | 0x8 | 0x1000 | (hasMips ? 0x20000 : 0)))   // caps, height, width, pitch, pixelformat, mips
            put(UInt32(image.height)); put(UInt32(image.width)); put(UInt32(image.width * 4))
            put(UInt32(0)); put(UInt32(levels.count))
            out.append(Data(count: 44))
            put(UInt32(32)); put(UInt32(0x41)); put(UInt32(0)); put(UInt32(32))      // RGB + alpha, no fourCC
            put(UInt32(0x00FF_0000)); put(UInt32(0x0000_FF00)); put(UInt32(0x0000_00FF)); put(UInt32(0xFF00_0000))
            put(UInt32(0x1000 | (hasMips ? 0x400008 : 0))); put(UInt32(0)); put(UInt32(0)); put(UInt32(0)); put(UInt32(0))
            for level in levels { out.append(bgra(level)) }                         // largest first
        } else {
            out.append(contentsOf: Array("TEX\0".utf8))
            put(UInt16(image.width)); put(UInt16(image.height))
            out.append(contentsOf: [1, 20, 0, hasMips ? 1 : 0])                    // BGRA8
            for level in levels.reversed() { out.append(bgra(level)) }              // smallest first
        }
        return out
    }

    // MARK: Pixel decoding

    private static func decodePixels(_ f: Pixels, _ src: Data, _ w: Int, _ h: Int) -> RGBAImage {
        var out = [UInt8](repeating: 0, count: w * h * 4)
        let s = [UInt8](src)
        switch f {
        case .bgra8:
            for i in 0 ..< w * h {
                out[i * 4] = s[i * 4 + 2]; out[i * 4 + 1] = s[i * 4 + 1]
                out[i * 4 + 2] = s[i * 4]; out[i * 4 + 3] = s[i * 4 + 3]
            }
        case .bc1, .bc3:
            let blockSize = f == .bc1 ? 8 : 16
            let bw = max(1, (w + 3) / 4), bh = max(1, (h + 3) / 4)
            for by in 0 ..< bh {
                for bx in 0 ..< bw {
                    let o = (by * bw + bx) * blockSize
                    var alpha = [UInt8](repeating: 255, count: 16)
                    if f == .bc3 { alpha = decodeAlphaBlock(s, o) }
                    let colors = decodeColorBlock(s, f == .bc3 ? o + 8 : o, fourColor: f == .bc3)
                    for py in 0 ..< 4 {
                        for px in 0 ..< 4 {
                            let x = bx * 4 + px, y = by * 4 + py
                            guard x < w, y < h else { continue }
                            let c = colors[py * 4 + px]
                            let d = (y * w + x) * 4
                            out[d] = c.0; out[d + 1] = c.1; out[d + 2] = c.2
                            out[d + 3] = f == .bc3 ? alpha[py * 4 + px] : c.3
                        }
                    }
                }
            }
        }
        return RGBAImage(width: w, height: h, pixels: out)
    }

    private static func decodeColorBlock(_ s: [UInt8], _ o: Int, fourColor: Bool) -> [(UInt8, UInt8, UInt8, UInt8)] {
        let c0 = Int(s[o]) | Int(s[o + 1]) << 8
        let c1 = Int(s[o + 2]) | Int(s[o + 3]) << 8
        func rgb(_ c: Int) -> (Int, Int, Int) {
            let r = (c >> 11) & 31, g = (c >> 5) & 63, b = c & 31
            return ((r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2))
        }
        let a = rgb(c0), b = rgb(c1)
        var palette: [(UInt8, UInt8, UInt8, UInt8)] = [
            (UInt8(a.0), UInt8(a.1), UInt8(a.2), 255), (UInt8(b.0), UInt8(b.1), UInt8(b.2), 255),
        ]
        if c0 > c1 || fourColor {
            palette.append((UInt8((2 * a.0 + b.0) / 3), UInt8((2 * a.1 + b.1) / 3), UInt8((2 * a.2 + b.2) / 3), 255))
            palette.append((UInt8((a.0 + 2 * b.0) / 3), UInt8((a.1 + 2 * b.1) / 3), UInt8((a.2 + 2 * b.2) / 3), 255))
        } else {
            palette.append((UInt8((a.0 + b.0) / 2), UInt8((a.1 + b.1) / 2), UInt8((a.2 + b.2) / 2), 255))
            palette.append((0, 0, 0, 0))
        }
        let bits = Int(s[o + 4]) | Int(s[o + 5]) << 8 | Int(s[o + 6]) << 16 | Int(s[o + 7]) << 24
        return (0 ..< 16).map { palette[(bits >> ($0 * 2)) & 3] }
    }

    private static func decodeAlphaBlock(_ s: [UInt8], _ o: Int) -> [UInt8] {
        let a0 = Int(s[o]), a1 = Int(s[o + 1])
        var table = [a0, a1]
        if a0 > a1 {
            for i in 1 ... 6 { table.append(((7 - i) * a0 + i * a1) / 7) }
        } else {
            for i in 1 ... 4 { table.append(((5 - i) * a0 + i * a1) / 5) }
            table += [0, 255]
        }
        var bits: UInt64 = 0
        for i in 0 ..< 6 { bits |= UInt64(s[o + 2 + i]) << (8 * UInt64(i)) }
        return (0 ..< 16).map { UInt8(table[Int((bits >> (3 * UInt64($0))) & 7)]) }
    }
}
