// Renders Prune's app icon (a leaf on a teal squircle) into an .icns.
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Prune.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let inset = s * 0.09
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowBlurRadius = s * 0.025
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.01)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.set()
    NSGradient(colors: [NSColor(red: 0.10, green: 0.62, blue: 0.55, alpha: 1), NSColor(red: 0.05, green: 0.36, blue: 0.47, alpha: 1)])!
        .draw(in: path, angle: -60)
    NSGraphicsContext.current?.restoreGraphicsState()
    let config = NSImage.SymbolConfiguration(pointSize: s * 0.46, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let leaf = NSImage(systemSymbolName: "leaf.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let ls = leaf.size
        leaf.draw(in: NSRect(x: (s - ls.width) / 2, y: (s - ls.height) / 2 - s * 0.01, width: ls.width, height: ls.height))
    }
    let sparkCfg = NSImage.SymbolConfiguration(pointSize: s * 0.16, weight: .bold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(red: 1, green: 0.9, blue: 0.55, alpha: 1)]))
    if let spark = NSImage(systemSymbolName: "sparkle", accessibilityDescription: nil)?.withSymbolConfiguration(sparkCfg) {
        spark.draw(in: NSRect(x: s * 0.64, y: s * 0.62, width: spark.size.width, height: spark.size.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: iconset.appendingPathComponent("icon_\(name).png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", URL(fileURLWithPath: outDir).appendingPathComponent("AppIcon.icns").path]
try! p.run(); p.waitUntilExit()
try? render(512).write(to: URL(fileURLWithPath: outDir).appendingPathComponent("AppIcon-preview.png"))
print("icon written to \(outDir)/AppIcon.icns")
