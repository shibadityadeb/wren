import AppKit
import CoreGraphics
import Vision
import WrenKit

/// Reads the user's logo (assets/logo.png): a black bird on a cream rounded tile with a
/// dark border, on a black background. Produces the app icon from the original pixels
/// and a vector trace of the bird for the menu bar and SVG master.
struct LogoSource {
    let image: CGImage
    let width: Int, height: Int
    let pixels: [UInt8]           // RGBA, row 0 = top
    let tile: CGRect              // outer edge of the tile (incl. border), y-down pixels
    let cornerRadius: CGFloat
    let interior: CGRect          // cream area inside the border

    init(url: URL) throws {
        guard let img = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let width = img.width, height = img.height
        image = img; self.width = width; self.height = height
        var buf = [UInt8](repeating: 0, count: width * height * 4)
        let ctx = CGContext(data: &buf, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: width, height: height))
        pixels = buf

        func lum(_ x: Int, _ y: Int) -> Int { let i = (y * width + x) * 4; return (Int(buf[i]) + Int(buf[i + 1]) + Int(buf[i + 2])) / 3 }
        let midY = height / 2, midX = width / 2
        let left = (0..<midX).first { lum($0, midY) > 12 } ?? 0
        let right = (midX..<width).reversed().first { lum($0, midY) > 12 } ?? width - 1
        let top = (0..<midY).first { lum(midX, $0) > 12 } ?? 0
        let bottom = (midY..<height).reversed().first { lum(midX, $0) > 12 } ?? height - 1
        tile = CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
        // Inner (cream) edge along the same scanlines.
        let iLeft = (left..<midX).first { lum($0, midY) > 200 } ?? left
        let iTop = (top..<midY).first { lum(midX, $0) > 200 } ?? top
        let border = CGFloat(max(iLeft - left, iTop - top))
        interior = tile.insetBy(dx: border, dy: border)
        // Corner radius from where the diagonal first meets the tile: d = r(1 - 1/√2).
        let d = (0..<midX).first { lum(left + $0, top + $0) > 12 } ?? 0
        cornerRadius = CGFloat(d) / (1 - 1 / sqrt(2))
    }

    var creamHex: String {
        let x = Int(interior.minX) + 20, y = Int(interior.midY), i = (y * width + x) * 4
        return String(format: "#%02X%02X%02X", pixels[i], pixels[i + 1], pixels[i + 2])
    }

    /// App icon on the macOS 1024 grid: the original tile scaled into the 824 px
    /// square, clipped to its own rounded corners so the black surround becomes transparent.
    func appIcon(size: Int) -> CGImage? {
        if size <= 32 { return smallAppIcon(size: size) }
        let s = CGFloat(size), unit = s / 1024
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        let dest = CGRect(x: 100 * unit, y: 100 * unit, width: 824 * unit, height: 824 * unit)
        let scale = dest.width / tile.width
        // Slightly inset the clip so no black anti-aliased fringe survives.
        let clip = dest.insetBy(dx: 0.6 * scale, dy: 0.6 * scale)
        ctx.addPath(CGPath(roundedRect: clip, cornerWidth: cornerRadius * scale, cornerHeight: cornerRadius * scale, transform: nil))
        ctx.clip()
        guard let cropped = image.cropping(to: tile) else { return nil }
        ctx.draw(cropped, in: dest)
        return ctx.makeImage()
    }

    /// At 16 and 32 px, downsampling the raster blurs the bird into a smudge. These sizes
    /// are drawn from the vector trace instead: same cream tile and dark border, the compact
    /// bird filling more of the tile, pixel-aligned.
    func smallAppIcon(size: Int) -> CGImage? {
        let s = CGFloat(size), unit = s / 1024
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: s); ctx.scaleBy(x: 1, y: -1)
        let tileRect = CGRect(x: 100 * unit, y: 100 * unit, width: 824 * unit, height: 824 * unit).integral
        let r = cornerRadius * tileRect.width / tile.width
        ctx.addPath(CGPath(roundedRect: tileRect, cornerWidth: r, cornerHeight: r, transform: nil))
        ctx.setFillColor(CGColor(srgbRed: 0.137, green: 0.137, blue: 0.137, alpha: 1)); ctx.fillPath()
        let border = max(1, tileRect.width * 0.025)
        let inner = tileRect.insetBy(dx: border, dy: border)
        ctx.addPath(CGPath(roundedRect: inner, cornerWidth: max(0, r - border), cornerHeight: max(0, r - border), transform: nil))
        ctx.setFillColor(CGColor(srgbRed: 251 / 255, green: 245 / 255, blue: 228 / 255, alpha: 1)); ctx.fillPath()
        var t = WrenMark.transform(into: inner, inset: 0.1)
        if let p = WrenMark.compactPath.copy(using: &t) { ctx.addPath(p); ctx.setFillColor(.black); ctx.fillPath(using: .evenOdd) }
        return ctx.makeImage()
    }

    /// Black-on-white mask of just the bird (dark pixels well inside the cream area).
    func birdMask() -> CGImage? {
        let inner = interior.insetBy(dx: interior.width * 0.04, dy: interior.height * 0.04)
        var out = [UInt8](repeating: 255, count: width * height)
        for y in Int(inner.minY)..<Int(inner.maxY) {
            for x in Int(inner.minX)..<Int(inner.maxX) {
                let i = (y * width + x) * 4
                let l = (Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2])) / 3
                out[y * width + x] = UInt8(clamping: l)
            }
        }
        let provider = CGDataProvider(data: Data(out) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Traces the bird with Vision. Returns contours in a 100-unit box, y-down,
    /// each tagged as outer (silhouette) or hole (eye and other cut-outs).
    func traceBird(epsilon: Float = 0.0006) throws -> [(points: [CGPoint], isHole: Bool)] {
        guard let mask = birdMask() else { throw CocoaError(.fileReadCorruptFile) }
        let req = VNDetectContoursRequest()
        req.detectsDarkOnLight = true
        req.contrastAdjustment = 1
        req.maximumImageDimension = 1024
        try VNImageRequestHandler(cgImage: mask, options: [:]).perform([req])
        guard let obs = req.results?.first else { return [] }
        var result: [(points: [CGPoint], isHole: Bool)] = []
        let side = max(interior.width, interior.height)
        func convert(_ c: VNContour, hole: Bool) throws {
            let poly = try c.polygonApproximation(epsilon: epsilon)
            // Normalized (0…1, y-up, whole image) → pixel → 100-box over the interior, y-down.
            let pts = poly.normalizedPoints.map { p -> CGPoint in
                let px = CGFloat(p.x) * CGFloat(width), py = (1 - CGFloat(p.y)) * CGFloat(height)
                return CGPoint(x: (px - interior.minX) / side * 100, y: (py - interior.minY) / side * 100)
            }
            if pts.count >= 3 { result.append((pts, hole)) }
            for child in c.childContours { try convert(child, hole: !hole) }
        }
        for c in obs.topLevelContours {
            // Skip specks (JPEG-style noise) smaller than 0.2% of the area.
            let poly = try c.polygonApproximation(epsilon: epsilon)
            if abs(area(poly.normalizedPoints)) < 0.00002 { continue }
            try convert(c, hole: false)
        }
        return result
    }

    private func area(_ pts: [simd_float2]) -> Float {
        guard pts.count > 2 else { return 0 }
        var a: Float = 0
        for i in pts.indices { let j = (i + 1) % pts.count; a += pts[i].x * pts[j].y - pts[j].x * pts[i].y }
        return a / 2
    }
}
