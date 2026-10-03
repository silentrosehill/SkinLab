import Foundation
import CoreGraphics
import Vision
import simd

/// One view of a character from a reference sheet ("Front", "3/4 Front", "Side"…).
struct SheetView {
    let label: String
    /// Camera angle around the character, in degrees: 0 front, negative toward the character's right, 180 back.
    let angle: Float
    let image: CGImage
    let width: Int
    let height: Int
    /// Character pixels (top row first).
    let mask: [Bool]
    /// Silhouette top and bottom rows, and the column of the body's vertical axis.
    let top: Int
    let bottom: Int
    let axis: Float

    func inside(_ col: Int, _ row: Int) -> Bool {
        col >= 0 && row >= 0 && col < width && row < height && mask[row * width + col]
    }
}

enum Sheet {
    static let angles: [String: Float] = ["front": 0, "3/4 front": -45, "side": -90, "3/4 back": -135, "back": 180]

    /// Finds the labelled full-body views on a character sheet and cuts the character out of each.
    static func read(_ sheet: CGImage) throws -> [SheetView] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: sheet).perform([request])
        let px = pixels(sheet)
        var views: [SheetView] = []
        for obs in request.results ?? [] {
            guard let text = obs.topCandidates(1).first?.string else { continue }
            let key = text.lowercased().trimmingCharacters(in: .whitespaces)
            guard let angle = angles[key], !views.contains(where: { $0.label.lowercased() == key }) else { continue }
            // Label box in pixels (Vision's origin is bottom-left).
            let b = obs.boundingBox
            let labelTop = Int((1 - b.maxY) * CGFloat(sheet.height))
            let labelMidX = Int(b.midX * CGFloat(sheet.width))
            guard let rect = pictureAbove(px, width: sheet.width, height: sheet.height, x: labelMidX, y: labelTop),
                  let crop = sheet.cropping(to: rect),
                  let view = cutOut(crop, label: text, angle: angle) else { continue }
            views.append(view)
        }
        guard views.contains(where: { $0.angle == 0 }) else { throw FormatError("No \"Front\" view found on this sheet") }
        guard views.contains(where: { $0.angle == -90 || $0.angle == 90 }) else { throw FormatError("No \"Side\" view found on this sheet") }
        return views.sorted { abs($0.angle) < abs($1.angle) }
    }

    private struct Pixels {
        let data: [UInt8]
        let width: Int
        func isPaper(_ x: Int, _ y: Int) -> Bool {
            let o = (y * width + x) * 4
            let r = Int(data[o]), g = Int(data[o + 1]), b = Int(data[o + 2])
            return min(r, g, b) > 200 && max(r, g, b) - min(r, g, b) < 24      // white / light grey card
        }
    }

    private static func pixels(_ image: CGImage) -> Pixels {
        var buf = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ctx = CGContext(data: &buf, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Pixels(data: buf, width: image.width)
    }

    /// The picture sitting just above a label: walk up to its bottom edge, out to its sides, then up its left
    /// edge (the middle can hold white clothes that look like the card).
    private static func pictureAbove(_ p: Pixels, width: Int, height: Int, x: Int, y: Int) -> CGRect? {
        var bottom = y - 2
        while bottom > 0 && p.isPaper(x, bottom) && y - bottom < 120 { bottom -= 1 }
        guard bottom > 4, !p.isPaper(x, bottom) else { return nil }
        let row = bottom - 3
        var left = x, right = x
        func cardAt(_ x: Int, _ dx: Int) -> Bool { (1 ... 5).allSatisfy { x + $0 * dx >= 0 && x + $0 * dx < width && p.isPaper(x + $0 * dx, row) } }
        while left > 0 && !cardAt(left, -1) { left -= 1 }
        while right < width - 1 && !cardAt(right, 1) { right += 1 }
        let edge = min(left + 6, right)
        var top = row
        // a lone light pixel (a star, a highlight) isn't the card: the card is a run of them
        func cardAbove(_ y: Int) -> Bool { (1 ... 5).allSatisfy { y - $0 >= 0 && p.isPaper(edge, y - $0) } }
        while top > 0 && !cardAbove(top) { top -= 1 }
        guard bottom - top > 60, right - left > 40 else { return nil }
        return CGRect(x: left + 2, y: top + 2, width: right - left - 4, height: bottom - top - 4)
    }

    /// The character's silhouette in one picture.
    static func cutOut(_ image: CGImage, label: String, angle: Float) -> SheetView? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        guard (try? handler.perform([request])) != nil, let obs = request.results?.first,
              let buffer = try? obs.generateScaledMaskForImage(forInstances: obs.allInstances, from: handler) else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        var mask = [Bool](repeating: false, count: w * h)
        for y in 0 ..< h {
            let line = base.advanced(by: y * row).assumingMemoryBound(to: Float.self)
            for x in 0 ..< w { mask[y * w + x] = line[x] > 0.5 }
        }
        let rows = (0 ..< h).filter { y in (0 ..< w).contains { mask[y * w + $0] } }
        guard let top = rows.first, let bottom = rows.last, bottom - top > 40 else { return nil }
        // Body axis: middle of the silhouette around the hips, where arms don't reach.
        let span = Float(bottom - top)
        var mids: [Float] = []
        for y in Int(Float(top) + span * 0.45) ... Int(Float(top) + span * 0.6) {
            let cols = (0 ..< w).filter { mask[y * w + $0] }
            if let a = cols.first, let b = cols.last { mids.append(Float(a + b) / 2) }
        }
        mids.sort()
        let axis = mids.isEmpty ? Float(w) / 2 : mids[mids.count / 2]
        return SheetView(label: label, angle: angle, image: image, width: w, height: h, mask: mask, top: top, bottom: bottom, axis: axis)
    }
}
