// Renders Resources/AppIcon.icns and Resources/AppIcon.png (same tile as ClipStack, with four stem faders).
// Usage: swift scripts/make-icon.swift
import AppKit

/// A continuous-corner rounded square (superellipse), the shape macOS app icons use.
func squircle(_ rect: NSRect, exponent: CGFloat = 5) -> NSBezierPath {
    let path = NSBezierPath()
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    let steps = 360
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * copysign(pow(abs(c), 2 / exponent), c)
        let y = cy + b * copysign(pow(abs(s), 2 / exponent), s)
        i == 0 ? path.move(to: NSPoint(x: x, y: y)) : path.line(to: NSPoint(x: x, y: y))
    }
    path.close()
    return path
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func withShadow(_ shadowColor: NSColor, blur: CGFloat, y: CGFloat, _ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = shadowColor
    shadow.shadowBlurRadius = blur
    shadow.shadowOffset = NSSize(width: 0, height: y)
    shadow.set()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

func rotated(around center: NSPoint, degrees: CGFloat, _ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let transform = NSAffineTransform()
    transform.translateX(by: center.x, yBy: center.y)
    transform.rotate(byDegrees: degrees)
    transform.translateX(by: -center.x, yBy: -center.y)
    transform.concat()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

func render(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let s = size / 1024
    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
        NSRect(x: x * s, y: y * s, width: w * s, height: h * s)
    }

    // Background tile with a deep indigo-to-violet gradient and a soft glow at the top.
    let tile = squircle(r(100, 100, 824, 824))
    withShadow(.black.withAlphaComponent(0.28), blur: 28 * s, y: -12 * s) {
        color(0x3B3FE0).setFill()
        tile.fill()
    }
    NSGradient(colors: [color(0x6F7BFF), color(0x4B3FE8), color(0x2B1C9E)],
               atLocations: [0, 0.55, 1], colorSpace: .sRGB)!.draw(in: tile, angle: -70)
    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    NSGradient(starting: color(0xFFFFFF, 0.35), ending: color(0xFFFFFF, 0))!
        .draw(fromCenter: NSPoint(x: 380 * s, y: 900 * s), radius: 0,
              toCenter: NSPoint(x: 380 * s, y: 900 * s), radius: 620 * s, options: [])
    NSGraphicsContext.restoreGraphicsState()
    color(0xFFFFFF, 0.18).setStroke()
    let rim = squircle(r(102, 102, 820, 820))
    rim.lineWidth = 3 * s
    rim.stroke()

    // A white card holding four faders, one per stem.
    let card = NSBezierPath(roundedRect: r(252, 250, 520, 524), xRadius: 84 * s, yRadius: 84 * s)
    withShadow(color(0x12086B, 0.45), blur: 40 * s, y: -18 * s) {
        color(0xFFFFFF).setFill()
        card.fill()
    }
    NSGradient(starting: color(0xFFFFFF), ending: color(0xEEF0FF))!.draw(in: card, angle: -90)

    let stems: [(UInt32, UInt32, CGFloat)] = [  // light, dark, knob height (0...1)
        (0xFF7A7E, 0xE5484D, 0.72), (0x7C9BFF, 0x3E63DD, 0.38), (0xFFC24D, 0xF59E0B, 0.86), (0x5DD39A, 0x30A46C, 0.55),
    ]
    let bottom: CGFloat = 330, top: CGFloat = 694
    for (i, (light, dark, level)) in stems.enumerated() {
        let x = 340 + CGFloat(i) * 115
        // Groove.
        color(0xDCDEF5).setFill()
        NSBezierPath(roundedRect: r(x - 14, bottom, 28, top - bottom), xRadius: 14 * s, yRadius: 14 * s).fill()
        // Filled part up to the knob.
        let y = bottom + (top - bottom) * level
        let fill = NSBezierPath(roundedRect: r(x - 14, bottom, 28, y - bottom), xRadius: 14 * s, yRadius: 14 * s)
        NSGradient(starting: color(light), ending: color(dark))!.draw(in: fill, angle: -90)
        // Knob.
        let knob = r(x - 38, y - 38, 76, 76)
        withShadow(color(dark, 0.45), blur: 12 * s, y: -5 * s) {
            color(0xFFFFFF).setFill()
            NSBezierPath(ovalIn: knob).fill()
        }
        color(dark).setStroke()
        let ring = NSBezierPath(ovalIn: knob.insetBy(dx: 7 * s, dy: 7 * s))
        ring.lineWidth = 10 * s
        ring.stroke()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}
let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let data = render(size: CGFloat(base * scale)).representation(using: .png, properties: [:])!
        try data.write(to: iconset.appendingPathComponent(name))
    }
}
let output = root.appendingPathComponent("Resources/AppIcon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try task.run()
task.waitUntilExit()
try render(size: 1024).representation(using: .png, properties: [:])!
    .write(to: root.appendingPathComponent("Resources/AppIcon.png"))
print("Wrote \(output.path)")
