// Renders the MacTranslate app icon and builds Resources/AppIcon.icns.
// Usage: swift Scripts/make_icon.swift
import AppKit

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func bubble(_ r: NSRect, radius: CGFloat, tailLeft: Bool) -> NSBezierPath {
    let p = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
    let tail = NSBezierPath()
    if tailLeft {
        tail.move(to: NSPoint(x: r.minX + radius * 0.55, y: r.minY + 8))
        tail.line(to: NSPoint(x: r.minX + radius * 0.25, y: r.minY - 78))
        tail.line(to: NSPoint(x: r.minX + radius * 1.45, y: r.minY + 8))
    } else {
        tail.move(to: NSPoint(x: r.maxX - radius * 0.55, y: r.minY + 8))
        tail.line(to: NSPoint(x: r.maxX - radius * 0.25, y: r.minY - 78))
        tail.line(to: NSPoint(x: r.maxX - radius * 1.45, y: r.minY + 8))
    }
    tail.close()
    p.append(tail)
    return p
}

func drawLetter(_ s: String, in r: NSRect, color c: NSColor, size: CGFloat) {
    let font = NSFont.systemFont(ofSize: size, weight: .heavy)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: c]
    let str = NSAttributedString(string: s, attributes: attrs)
    let b = str.size()
    str.draw(at: NSPoint(x: r.midX - b.width / 2, y: r.midY - b.height / 2 + size * 0.02))
}

func render(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)

    // Background squircle (macOS icon grid: 824pt body, 100pt inset).
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let bg = NSBezierPath(roundedRect: body, xRadius: 186, yRadius: 186)
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow()
    sh.shadowColor = NSColor.black.withAlphaComponent(0.35)
    sh.shadowBlurRadius = 28
    sh.shadowOffset = NSSize(width: 0, height: -12)
    sh.set()
    color(0x3B5BDB).setFill()
    bg.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    bg.addClip()
    NSGradient(colors: [color(0x5B8CFF), color(0x6A4CE6), color(0x8B3FD9)], atLocations: [0, 0.55, 1],
               colorSpace: .sRGB)!.draw(in: body, angle: -60)
    // Soft top highlight.
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: 100, y: 560, width: 824, height: 364), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // Back bubble: Latin "A".
    let r1 = NSRect(x: 196, y: 470, width: 400, height: 330)
    NSGraphicsContext.saveGraphicsState()
    let s1 = NSShadow()
    s1.shadowColor = NSColor.black.withAlphaComponent(0.25)
    s1.shadowBlurRadius = 24
    s1.shadowOffset = NSSize(width: 0, height: -10)
    s1.set()
    NSColor.white.setFill()
    bubble(r1, radius: 92, tailLeft: true).fill()
    NSGraphicsContext.restoreGraphicsState()
    drawLetter("A", in: r1, color: color(0x4A5FE0), size: 250)

    // Front bubble: Cyrillic "Я".
    let r2 = NSRect(x: 428, y: 262, width: 400, height: 330)
    NSGraphicsContext.saveGraphicsState()
    let s2 = NSShadow()
    s2.shadowColor = NSColor.black.withAlphaComponent(0.3)
    s2.shadowBlurRadius = 30
    s2.shadowOffset = NSSize(width: 0, height: -12)
    s2.set()
    let b2 = bubble(r2, radius: 92, tailLeft: false)
    color(0xFFC94A).setFill()
    b2.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    b2.addClip()
    NSGradient(colors: [color(0xFFD866), color(0xFFA83A)])!.draw(in: r2.insetBy(dx: 0, dy: -80), angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    drawLetter("Я", in: r2, color: color(0x2B1F66), size: 250)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! render(px).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
try! render(1024).representation(using: .png, properties: [:])!
    .write(to: root.appendingPathComponent("Resources/AppIcon.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try! p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
