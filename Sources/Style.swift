import Foundation
import CoreGraphics
import Vision
import simd

/// Main colors of an image, in Lab (L 0…100), biggest area first.
struct Palette: Equatable {
    var colors: [SIMD3<Float>]
    var weights: [Float]

    var rgb: [SIMD3<Float>] { colors.map(ColorMath.rgb) }
}

enum ColorMath {
    private static func lin(_ c: Float) -> Float { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    private static func gam(_ c: Float) -> Float { c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055 }

    /// sRGB 0…1 → Lab (D65).
    static func lab(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let r = lin(c.x), g = lin(c.y), b = lin(c.z)
        let x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
        func f(_ t: Float) -> Float { t > 0.008856 ? cbrt(t) : 7.787 * t + 16 / 116 }
        let fx = f(x), fy = f(y), fz = f(z)
        return SIMD3(116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    /// Lab → sRGB 0…1 (clamped).
    static func rgb(_ l: SIMD3<Float>) -> SIMD3<Float> {
        let fy = (l.x + 16) / 116, fx = fy + l.y / 500, fz = fy - l.z / 200
        func inv(_ t: Float) -> Float { t * t * t > 0.008856 ? t * t * t : (t - 16 / 116) / 7.787 }
        let x = inv(fx) * 0.95047, y = inv(fy), z = inv(fz) * 1.08883
        let r = 3.2406 * x - 1.5372 * y - 0.4986 * z
        let g = -0.9689 * x + 1.8758 * y + 0.0415 * z
        let b = 0.0557 * x - 0.2040 * y + 1.0570 * z
        return simd_clamp(SIMD3(gam(max(r, 0)), gam(max(g, 0)), gam(max(b, 0))), SIMD3(repeating: 0), SIMD3(repeating: 1))
    }

    /// Roughly skin-colored (light to dark, any warm skin tone).
    static func isSkin(_ l: SIMD3<Float>) -> Bool {
        let chroma = simd_length(SIMD2(l.y, l.z))
        let hue = atan2(l.z, l.y) * 180 / .pi
        return l.x > 30 && l.x < 92 && chroma > 8 && chroma < 45 && hue > 10 && hue < 80
    }
}

enum Style {
    /// k-means with a fixed seed, so the same image always gives the same palette.
    static func kMeans(_ labPoints: [SIMD3<Float>], k: Int, iterations: Int = 14) -> Palette {
        guard !labPoints.isEmpty else { return Palette(colors: [], weights: []) }
        // Hue differences count double, so a dark green and a dark brown don't merge.
        let boost = SIMD3<Float>(1, 2, 2)
        let pts = labPoints.map { $0 * boost }
        let k = min(k, pts.count)
        var rng = UInt64(0x9E37_79B9_7F4A_7C15)
        func rand() -> Float {
            rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
            return Float(rng % 1_000_000) / 1_000_000
        }
        // k-means++ start
        var centers = [pts[pts.count / 2]]
        while centers.count < k {
            let d = pts.map { p in centers.map { simd_distance_squared(p, $0) }.min()! }
            let total = d.reduce(0, +)
            guard total > 0 else { break }
            var pick = rand() * total
            var idx = 0
            while idx < d.count - 1 && pick > d[idx] { pick -= d[idx]; idx += 1 }
            centers.append(pts[idx])
        }
        var assign = [Int](repeating: 0, count: pts.count)
        for _ in 0 ..< iterations {
            for (i, p) in pts.enumerated() {
                var best = 0, bestD = Float.greatestFiniteMagnitude
                for (c, center) in centers.enumerated() {
                    let d = simd_distance_squared(p, center)
                    if d < bestD { bestD = d; best = c }
                }
                assign[i] = best
            }
            var sums = [SIMD3<Float>](repeating: .zero, count: centers.count)
            var counts = [Float](repeating: 0, count: centers.count)
            for (i, p) in pts.enumerated() { sums[assign[i]] += p; counts[assign[i]] += 1 }
            for c in centers.indices where counts[c] > 0 { centers[c] = sums[c] / counts[c] }
        }
        var counts = [Float](repeating: 0, count: centers.count)
        for a in assign { counts[a] += 1 }
        let order = centers.indices.filter { counts[$0] > 0 }.sorted { counts[$0] > counts[$1] }
        return Palette(colors: order.map { centers[$0] / boost }, weights: order.map { counts[$0] / Float(pts.count) })
    }

    /// Pixels of an image drawn small, as sRGB 0…1, top row first.
    private static func samples(_ image: CGImage, side: Int) -> (pixels: [SIMD3<Float>], width: Int, height: Int) {
        let aspect = Float(image.width) / Float(max(image.height, 1))
        let w = aspect >= 1 ? side : max(8, Int(Float(side) * aspect))
        let h = aspect >= 1 ? max(8, Int(Float(side) / aspect)) : side
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var out: [SIMD3<Float>] = []
        out.reserveCapacity(w * h)
        for i in 0 ..< w * h {
            out.append(SIMD3(Float(buf[i * 4]), Float(buf[i * 4 + 1]), Float(buf[i * 4 + 2])) / 255)
        }
        return (out, w, h)
    }

    /// Colors of the subject of a picture (its background cut away by Vision when it can find one).
    static func palette(ofPicture image: CGImage, colors k: Int = 6) -> (palette: Palette, foundSubject: Bool) {
        let s = samples(image, side: 160)
        var keep = [Bool](repeating: true, count: s.pixels.count)
        var found = false
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        if (try? handler.perform([request])) != nil, let obs = request.results?.first,
           let mask = try? obs.generateScaledMaskForImage(forInstances: obs.allInstances, from: handler) {
            CVPixelBufferLockBaseAddress(mask, .readOnly)
            let mw = CVPixelBufferGetWidth(mask), mh = CVPixelBufferGetHeight(mask)
            let row = CVPixelBufferGetBytesPerRow(mask)
            if let base = CVPixelBufferGetBaseAddress(mask), CVPixelBufferGetPixelFormatType(mask) == kCVPixelFormatType_OneComponent32Float {
                for y in 0 ..< s.height {
                    for x in 0 ..< s.width {
                        let mx = min(mw - 1, x * mw / s.width), my = min(mh - 1, y * mh / s.height)
                        let v = base.advanced(by: my * row + mx * 4).assumingMemoryBound(to: Float.self).pointee
                        keep[y * s.width + x] = v > 0.5
                    }
                }
                found = keep.contains(true)
            }
            CVPixelBufferUnlockBaseAddress(mask, .readOnly)
        }
        if !found { keep = keep.map { _ in true } }
        let pts = zip(s.pixels, keep).filter(\.1).map { ColorMath.lab($0.0) }
        return (kMeans(pts, k: k), found)
    }

    /// Main color regions of a texture.
    static func palette(ofTexture image: CGImage, colors k: Int = 6) -> Palette {
        kMeans(samples(image, side: 96).pixels.map(ColorMath.lab), k: k)
    }

    /// Which picture color each texture color becomes: one of similar lightness, skin staying skin. -1 keeps the color (near-black lines and empty texture space).
    static func autoMap(texture: Palette, picture: Palette, keepSkin: Bool) -> [Int] {
        var mapping = [Int](repeating: -1, count: texture.colors.count)
        guard !picture.colors.isEmpty else { return mapping }
        let pictureSkin = keepSkin ? picture.colors.indices.first { ColorMath.isSkin(picture.colors[$0]) } : nil
        var pics = picture.colors.indices.filter { $0 != pictureSkin }
        if pics.isEmpty { pics = Array(picture.colors.indices) }
        var texs: [Int] = []
        for (i, c) in texture.colors.enumerated() {
            if c.x < 12 { continue }
            if keepSkin && ColorMath.isSkin(c) { mapping[i] = pictureSkin ?? -1; continue }
            texs.append(i)
        }
        // Biggest regions choose first: the picture color closest in lightness, preferring ones not taken yet.
        texs.sort { texture.weights[$0] > texture.weights[$1] }
        var uses = [Int: Int]()
        for i in texs {
            let best = pics.min { a, b in
                abs(texture.colors[i].x - picture.colors[a].x) + Float(uses[a, default: 0]) * 14
                    < abs(texture.colors[i].x - picture.colors[b].x) + Float(uses[b, default: 0]) * 14
            }!
            mapping[i] = best
            uses[best, default: 0] += 1
        }
        return mapping
    }

    /// A color lookup table (for CIColorCube) that moves each texture color region to its picture color,
    /// keeping the texture's own shading.
    static func lut(texture: Palette, picture: Palette, mapping: [Int], strength: Float, size n: Int = 32) -> Data {
        let deltas: [SIMD3<Float>] = texture.colors.indices.map { i in
            let j = i < mapping.count ? mapping[i] : -1
            guard j >= 0 && j < picture.colors.count else { return .zero }
            let t = texture.colors[i], p = picture.colors[j]
            return SIMD3((p.x - t.x) * 0.65, p.y - t.y, p.z - t.z)
        }
        var cube = [Float](repeating: 0, count: n * n * n * 4)
        let sigma2: Float = 2 * 16 * 16
        let boost = SIMD3<Float>(1, 2, 2)          // same hue-aware distance as the clustering
        let centers = texture.colors.map { $0 * boost }
        for b in 0 ..< n {
            for g in 0 ..< n {
                for r in 0 ..< n {
                    let rgb = SIMD3(Float(r), Float(g), Float(b)) / Float(n - 1)
                    let lab = ColorMath.lab(rgb)
                    var wsum: Float = 0
                    var delta = SIMD3<Float>(0, 0, 0)
                    let d2 = centers.map { simd_distance_squared(lab * boost, $0) }
                    let m = d2.min() ?? 0
                    for (i, d) in d2.enumerated() {
                        let w = exp(-(d - m) / sigma2)
                        wsum += w
                        delta += w * deltas[i]
                    }
                    let out = wsum > 0 ? ColorMath.rgb(lab + strength * delta / wsum) : rgb
                    let o = ((b * n + g) * n + r) * 4
                    cube[o] = out.x; cube[o + 1] = out.y; cube[o + 2] = out.z; cube[o + 3] = 1
                }
            }
        }
        return cube.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
