// Draws the app icon and packs it into an .icns file. Run it when the icon has to be changed:
//
//     swift scripts/make-icon.swift Resources/AppIcon.icns
//
// The result is committed, so it is not needed to build the app.

import AppKit

/// The icon on a 1024x1024 canvas: a speaker with a pulse instead of sound waves. It is alive!
func drawIcon() {
    // The plate: a rounded square with the standard margins of macOS icons.
    let plate = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.shadowBlurRadius = 24
    shadow.set()
    NSColor(red: 0.13, green: 0.17, blue: 0.42, alpha: 1).setFill()
    plate.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [
        NSColor(red: 0.33, green: 0.47, blue: 0.98, alpha: 1),
        NSColor(red: 0.20, green: 0.24, blue: 0.66, alpha: 1),
        NSColor(red: 0.11, green: 0.13, blue: 0.38, alpha: 1),
    ])?.draw(in: plate, angle: -90)

    // A soft highlight at the top.
    NSGraphicsContext.saveGraphicsState()
    plate.addClip()
    NSGradient(starting: NSColor(white: 1, alpha: 0.16), ending: NSColor(white: 1, alpha: 0))?
        .draw(in: NSRect(x: 100, y: 512, width: 824, height: 412), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    NSColor.white.set()

    // The speaker.
    let speaker = NSBezierPath()
    speaker.move(to: NSPoint(x: 236, y: 438))
    speaker.line(to: NSPoint(x: 330, y: 438))
    speaker.line(to: NSPoint(x: 452, y: 330))
    speaker.line(to: NSPoint(x: 452, y: 694))
    speaker.line(to: NSPoint(x: 330, y: 586))
    speaker.line(to: NSPoint(x: 236, y: 586))
    speaker.close()
    speaker.lineJoinStyle = .round
    speaker.lineWidth = 44
    speaker.fill()
    speaker.stroke()

    // The pulse.
    let pulse = NSBezierPath()
    pulse.move(to: NSPoint(x: 548, y: 512))
    pulse.line(to: NSPoint(x: 600, y: 512))
    pulse.line(to: NSPoint(x: 640, y: 596))
    pulse.line(to: NSPoint(x: 698, y: 352))
    pulse.line(to: NSPoint(x: 752, y: 672))
    pulse.line(to: NSPoint(x: 792, y: 512))
    pulse.line(to: NSPoint(x: 836, y: 512))
    pulse.lineJoinStyle = .round
    pulse.lineCapStyle = .round
    pulse.lineWidth = 42
    pulse.stroke()
}

func png(pixels: Int) -> Data {
    let representation = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)

    let transform = NSAffineTransform()
    transform.scale(by: CGFloat(pixels) / 1024)
    transform.concat()
    drawIcon()

    NSGraphicsContext.restoreGraphicsState()
    return representation.representation(using: .png, properties: [:])!
}

guard CommandLine.arguments.count == 2 else {
    print("usage: swift make-icon.swift <output.icns | output.png>")
    exit(64)
}

let output = URL(fileURLWithPath: CommandLine.arguments[1])

if output.pathExtension == "png" {
    try png(pixels: 1024).write(to: output)
    exit(0)
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("SoundKeeper-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

for points in [16, 32, 128, 256, 512] {
    try png(pixels: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try png(pixels: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["--convert", "icns", "--output", output.path, iconset.path]
try iconutil.run()
iconutil.waitUntilExit()
exit(iconutil.terminationStatus)
