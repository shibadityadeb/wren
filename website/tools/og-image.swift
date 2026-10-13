// Renders website/assets/og-image.png (1200×630) from the real app icon and the site's fonts.
//   swift website/tools/og-image.swift && sips -z 630 1200 website/assets/og-image.png   (renders at 2×, then scales to 1200×630)
import AppKit
import CoreText

let site = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
for f in ["fraunces-variable.woff2", "figtree-variable.woff2"] {
    CTFontManagerRegisterFontsForURL(site.appendingPathComponent("assets/fonts/\(f)") as CFURL, .process, nil)
}

func font(_ family: String, _ size: CGFloat, weight: CGFloat, opsz: CGFloat? = nil) -> NSFont {
    var axes: [Int: CGFloat] = [0x77676874: weight]          // 'wght'
    if let opsz { axes[0x6F70737A] = opsz }                   // 'opsz'
    let d = NSFontDescriptor(fontAttributes: [.family: family, NSFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): axes])
    return NSFont(descriptor: d, size: size) ?? NSFont.systemFont(ofSize: size)
}

let size = NSSize(width: 1200, height: 630)
let image = NSImage(size: size)
image.lockFocus()
NSColor(red: 0xF7 / 255, green: 0xF3 / 255, blue: 0xEA / 255, alpha: 1).setFill()
NSRect(origin: .zero, size: size).fill()
// Thin editorial rules.
NSColor(red: 0xE3 / 255, green: 0xDD / 255, blue: 0xD0 / 255, alpha: 1).setFill()
NSRect(x: 0, y: 112, width: 1200, height: 1).fill()

let icon = NSImage(contentsOf: site.appendingPathComponent("assets/brand/wren-icon-512.png"))!
icon.draw(in: NSRect(x: 84, y: 250, width: 220, height: 220))

let ink = NSColor(red: 0x26 / 255, green: 0x23 / 255, blue: 0x1F / 255, alpha: 1)
let blue = NSColor(red: 0x4C / 255, green: 0x6F / 255, blue: 0x96 / 255, alpha: 1)
let muted = NSColor(red: 0x7A / 255, green: 0x75 / 255, blue: 0x6C / 255, alpha: 1)
let serif = font("Fraunces", 66, weight: 600, opsz: 144)
func draw(_ s: String, _ f: NSFont, _ c: NSColor, at p: NSPoint, kern: CGFloat = 0) {
    NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: c, .kern: kern]).draw(at: p)
}
draw("A little less to remember.", serif, ink, at: NSPoint(x: 352, y: 380), kern: -1)
draw("A little more room to think.", serif, blue, at: NSPoint(x: 352, y: 302), kern: -1)
draw("A QUIET COMPANION FOR YOUR MAC", font("Figtree", 18, weight: 600), muted, at: NSPoint(x: 356, y: 478), kern: 3.4)
draw("Wren", font("Fraunces", 40, weight: 600, opsz: 72), ink, at: NSPoint(x: 84, y: 44))
draw("In development · Free during the preview", font("Figtree", 22, weight: 500), muted, at: NSPoint(x: 700, y: 54))
image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
let out = site.appendingPathComponent("assets/og-image.png")
try! rep.representation(using: .png, properties: [:])!.write(to: out)
print("wrote \(out.path) \(rep.pixelsWide)×\(rep.pixelsHigh)")
