// Draws the app icon (an open book with a sound wave) and writes Resources/AppIcon.icns.
//   swift make_icon.swift
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// macOS icon grid: an 824-point rounded square centred on the 1024 canvas
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(calibratedRed: 0.16, green: 0.38, blue: 0.78, alpha: 1),
           ending: NSColor(calibratedRed: 0.07, green: 0.18, blue: 0.45, alpha: 1))!
    .draw(in: shape, angle: -90)

func symbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSImage {
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(config)!
}

func draw(_ img: NSImage, centeredAt center: NSPoint) {
    let s = img.size
    img.draw(in: NSRect(x: center.x - s.width / 2, y: center.y - s.height / 2, width: s.width, height: s.height))
}

draw(symbol("book.fill", pointSize: 330, weight: .regular, color: .white), centeredAt: NSPoint(x: 512, y: 590))
draw(symbol("waveform", pointSize: 230, weight: .semibold,
            color: NSColor(calibratedRed: 1.0, green: 0.78, blue: 0.35, alpha: 1)),
     centeredAt: NSPoint(x: 512, y: 300))
image.unlockFocus()

// Write every size iconutil expects, then pack them into an .icns
let iconset = URL(fileURLWithPath: "build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let tiff = image.tiffRepresentation!
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(data: tiff)!.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
