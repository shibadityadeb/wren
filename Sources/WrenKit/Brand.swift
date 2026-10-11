import AppKit
import CoreGraphics
import SwiftUI

/// Wren's brand mark: the hummingbird from the user's logo (assets/logo.png),
/// traced to vector by `wren-tools trace` into WrenMarkData.swift. The SVG master,
/// menu-bar template and in-app logo all come from that one trace.
///
/// Coordinates are a 100-unit box over the logo's cream tile, y pointing down.
public enum WrenMark {
    static func polygon(_ flat: [Double]) -> CGPath {
        let p = CGMutablePath()
        let pts = stride(from: 0, to: flat.count - 1, by: 2).map { CGPoint(x: flat[$0], y: flat[$0 + 1]) }
        if !pts.isEmpty { p.addLines(between: pts); p.closeSubpath() }
        return p
    }

    static var outline: CGPath {
        outlines.map(polygon).reduce(CGMutablePath() as CGPath) { $0.isEmpty ? $1 : $0.union($1) }
    }
    static var holePaths: [CGPath] { holes.map(polygon) }

    /// Full-detail mark. Use at 32 px and above.
    public static let path: CGPath = holePaths.reduce(outline) { $0.subtracting($1) }

    /// Small-size mark for the menu bar: the silhouette is thickened slightly so the
    /// beak and feather tips survive at 16–18 pt, and the eye is enlarged so it
    /// doesn't close up after pixel snapping.
    public static let compactPath: CGPath = {
        let o = outline
        let thick = o.union(o.copy(strokingWithWidth: 1.6, lineCap: .round, lineJoin: .round, miterLimit: 4))
        return holePaths.reduce(thick) { mark, hole in
            let b = hole.boundingBoxOfPath
            var t = CGAffineTransform(translationX: b.midX, y: b.midY).scaledBy(x: 1.7, y: 1.7).translatedBy(x: -b.midX, y: -b.midY)
            return mark.subtracting(hole.copy(using: &t) ?? hole)
        }
    }()

    /// Tight bounds of the silhouette, used to centre it optically.
    public static var bounds: CGRect { path.isEmpty ? CGRect(x: 0, y: 0, width: 100, height: 100) : path.boundingBoxOfPath }

    /// Transform mapping the mark into `rect` (y-down), fitted with `inset` fraction of padding.
    public static func transform(into rect: CGRect, inset: CGFloat = 0.08) -> CGAffineTransform {
        let b = bounds
        let avail = rect.insetBy(dx: rect.width * inset, dy: rect.height * inset)
        let s = min(avail.width / b.width, avail.height / b.height)
        let tx = avail.midX - b.midX * s
        let ty = avail.midY - b.midY * s
        return CGAffineTransform(a: s, b: 0, c: 0, d: s, tx: tx, ty: ty)
    }

    /// SVG path data in the 100-unit box.
    public static func svgPathData(_ path: CGPath = path) -> String {
        var d = ""
        func f(_ v: CGFloat) -> String { String(format: "%.2f", v).replacingOccurrences(of: ".00", with: "") }
        path.applyWithBlock { el in
            let e = el.pointee, p = e.points
            switch e.type {
            case .moveToPoint: d += "M\(f(p[0].x)) \(f(p[0].y))"
            case .addLineToPoint: d += "L\(f(p[0].x)) \(f(p[0].y))"
            case .addQuadCurveToPoint: d += "Q\(f(p[0].x)) \(f(p[0].y)) \(f(p[1].x)) \(f(p[1].y))"
            case .addCurveToPoint: d += "C\(f(p[0].x)) \(f(p[0].y)) \(f(p[1].x)) \(f(p[1].y)) \(f(p[2].x)) \(f(p[2].y))"
            case .closeSubpath: d += "Z"
            @unknown default: break
            }
        }
        return d
    }

    /// Menu-bar template image. Template images are tinted by macOS for light, dark and highlighted states.
    /// `listening`: a small dot marks that Wren is listening for "Hey Wren" (or capturing).
    public static func menuBarImage(pointSize: CGFloat = 18, listening: Bool = false) -> NSImage {
        let img = NSImage(size: NSSize(width: pointSize, height: pointSize), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            var t = transform(into: rect, inset: listening ? 0.12 : 0.02)
            if let p = compactPath.copy(using: &t) { ctx.addPath(p); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath(using: .evenOdd) }
            if listening {
                let d = rect.width * 0.3
                ctx.fillEllipse(in: CGRect(x: rect.maxX - d, y: rect.maxY - d, width: d, height: d))
            }
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = listening ? "Wren, listening for Hey Wren" : "Wren"
        return img
    }
}

/// SwiftUI shape for the mark, for use inside the app.
public struct WrenMarkShape: Shape {
    public var compact: Bool
    public init(compact: Bool = false) { self.compact = compact }
    public func path(in rect: CGRect) -> Path {
        let source = compact || rect.width < 28 ? WrenMark.compactPath : WrenMark.path
        var t = WrenMark.transform(into: rect, inset: 0)
        return Path(source.copy(using: &t) ?? source)
    }
}

/// Design tokens. Mirrors Brand/tokens.json.
public enum WrenTheme {
    /// Cream sampled from the logo tile.
    public static let ivory = Color(hex: 0xFBF5E4)
    public static let charcoal = Color(hex: 0x1C1C1A)
    public static let moss = Color(hex: 0x5B6B4B)
    public static let mossLight = Color(hex: 0x9DB08A)
    public static let grey = Color(hex: 0x8A8A85)

    /// Accent that stays legible in both appearances.
    public static let accent = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: 0x9DB08A) : NSColor(hex: 0x5B6B4B)
    })

    public enum Space { public static let xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12, l: CGFloat = 16, xl: CGFloat = 24 }
    public enum Radius { public static let control: CGFloat = 6, panel: CGFloat = 14 }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
