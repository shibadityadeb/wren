import AppKit
import CoreGraphics

/// Renders mark previews for legibility checks. Used by `wren-tools assets`.
public enum IconRenderer {

    /// The bare mark on a solid background, for legibility checks at small sizes.
    public static func markPreview(size: Int, foreground: CGColor, background: CGColor?, inset: CGFloat = 0.02, compact: Bool? = nil) -> CGImage? {
        let s = CGFloat(size)
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: s); ctx.scaleBy(x: 1, y: -1)
        if let background { ctx.setFillColor(background); ctx.fill(CGRect(x: 0, y: 0, width: s, height: s)) }
        var t = WrenMark.transform(into: CGRect(x: 0, y: 0, width: s, height: s), inset: inset)
        let source = (compact ?? (size < 28)) ? WrenMark.compactPath : WrenMark.path
        if let p = source.copy(using: &t) { ctx.addPath(p); ctx.setFillColor(foreground); ctx.fillPath(using: .evenOdd) }
        return ctx.makeImage()
    }

    public static func writePNG(_ img: CGImage, to url: URL) throws {
        let rep = NSBitmapImageRep(cgImage: img)
        guard let data = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
}
