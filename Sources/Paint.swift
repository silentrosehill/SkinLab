import Foundation
import CoreGraphics

/// Hand-painted fixes on a texture: a layer painted over the (recolored) texture, kept separately so it can be erased.
final class PaintLayer {
    let width: Int, height: Int
    /// RGBA, not premultiplied; alpha is how much paint covers the texture.
    var pixels: [UInt8]
    private var undo: [[UInt8]] = []

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        pixels = [UInt8](repeating: 0, count: width * height * 4)
    }

    var isEmpty: Bool { !stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] > 0 } }
    var canUndo: Bool { !undo.isEmpty }

    /// Call at the start of a stroke (one undo step per stroke).
    func beginStroke() {
        undo.append(pixels)
        if undo.count > 20 { undo.removeFirst() }
    }

    func undoStroke() { if let last = undo.popLast() { pixels = last } }

    func clear() { beginStroke(); pixels = [UInt8](repeating: 0, count: pixels.count) }

    enum Tool: String, CaseIterable, Identifiable {
        case paint = "Paint", smooth = "Smooth", erase = "Erase", pick = "Pick Color"
        var id: String { rawValue }
    }

    /// One dab of the brush at texture position (x, y) in pixels. `under` is the texture under the paint (recolor
    /// included), `shown` the texture as it looks now (with the paint), both RGBA. Positions wrap around the texture's edges like the model's UVs.
    func dab(tool: Tool, x: Float, y: Float, radius: Float, strength: Float, color: (r: Float, g: Float, b: Float), under: [UInt8], shown: [UInt8]) {
        guard under.count == pixels.count, shown.count == pixels.count else { return }
        let r = max(radius, 0.5)
        let x0 = Int((x - r).rounded(.down)), x1 = Int((x + r).rounded(.up))
        let y0 = Int((y - r).rounded(.down)), y1 = Int((y + r).rounded(.up))
        func wrap(_ v: Int, _ n: Int) -> Int { ((v % n) + n) % n }
        // Smoothing: the average color around the brush, painted back softly.
        var avg: (Float, Float, Float) = (0, 0, 0)
        if tool == .smooth {
            var n: Float = 0
            for py in stride(from: y0, through: y1, by: max(1, Int(r / 6))) {
                for px in stride(from: x0, through: x1, by: max(1, Int(r / 6))) {
                    let i = (wrap(py, height) * width + wrap(px, width)) * 4
                    avg.0 += Float(shown[i]); avg.1 += Float(shown[i + 1]); avg.2 += Float(shown[i + 2]); n += 1
                }
            }
            if n > 0 { avg = (avg.0 / n, avg.1 / n, avg.2 / n) }
        }
        for py in y0 ... y1 {
            for px in x0 ... x1 {
                let dx = Float(px) + 0.5 - x, dy = Float(py) + 0.5 - y
                let d = (dx * dx + dy * dy).squareRoot() / r
                guard d < 1 else { continue }
                let falloff = 1 - d * d * (3 - 2 * d)                 // soft edge
                let a = min(max(falloff * strength, 0), 1)
                let i = (wrap(py, height) * width + wrap(px, width)) * 4
                let oldA = Float(pixels[i + 3]) / 255
                switch tool {
                case .paint, .smooth:
                    let src: (Float, Float, Float) = tool == .paint ? (color.r * 255, color.g * 255, color.b * 255) : avg
                    // What shows now (texture with paint over it), then that mixed toward the new color.
                    let showR = Float(pixels[i]) * oldA + Float(under[i]) * (1 - oldA)
                    let showG = Float(pixels[i + 1]) * oldA + Float(under[i + 1]) * (1 - oldA)
                    let showB = Float(pixels[i + 2]) * oldA + Float(under[i + 2]) * (1 - oldA)
                    let newA = oldA + a * (1 - oldA)
                    // Paint layer color such that layer over texture = show mixed with src by a.
                    let target = (showR + (src.0 - showR) * a, showG + (src.1 - showG) * a, showB + (src.2 - showB) * a)
                    let base = (Float(under[i]), Float(under[i + 1]), Float(under[i + 2]))
                    func solve(_ t: Float, _ b: Float) -> UInt8 { UInt8(min(max((t - b * (1 - newA)) / max(newA, 0.001), 0), 255)) }
                    pixels[i] = solve(target.0, base.0)
                    pixels[i + 1] = solve(target.1, base.1)
                    pixels[i + 2] = solve(target.2, base.2)
                    pixels[i + 3] = UInt8(min(newA * 255, 255))
                case .erase:
                    pixels[i + 3] = UInt8(oldA * (1 - a) * 255)
                case .pick:
                    break
                }
            }
        }
    }

    /// `under` with the paint on top.
    func composite(over under: [UInt8]) -> [UInt8] {
        var out = under
        for i in stride(from: 0, to: min(out.count, pixels.count), by: 4) where pixels[i + 3] > 0 {
            let a = Float(pixels[i + 3]) / 255
            for c in 0 ..< 3 { out[i + c] = UInt8(Float(pixels[i + c]) * a + Float(under[i + c]) * (1 - a)) }
        }
        return out
    }

    static func rgba(_ image: CGImage, width: Int, height: Int) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: width * height * 4)
        let ctx = CGContext(data: &px, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // un-premultiply
        for i in stride(from: 0, to: px.count, by: 4) where px[i + 3] > 0 && px[i + 3] < 255 {
            let a = Float(px[i + 3]) / 255
            for c in 0 ..< 3 { px[i + c] = UInt8(min(Float(px[i + c]) / a, 255)) }
        }
        return px
    }

    static func image(_ px: [UInt8], width: Int, height: Int) -> CGImage? {
        var premul = px
        for i in stride(from: 0, to: premul.count, by: 4) where premul[i + 3] < 255 {
            let a = Float(premul[i + 3]) / 255
            for c in 0 ..< 3 { premul[i + c] = UInt8(Float(premul[i + c]) * a) }
        }
        return premul.withUnsafeMutableBytes { buf in
            CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
    }
}
