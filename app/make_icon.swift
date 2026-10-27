// Makes the app icon from Resources/AppIcon-artwork.png and writes Resources/AppIcon.icns.
// The artwork's rounded square is cut out of its background (which may be solid black, not transparent)
// and placed on Apple's icon grid, so it sits the same size as other icons in the Dock.
//   swift make_icon.swift
import AppKit

let artwork = NSImage(contentsOfFile: "Resources/AppIcon-artwork.png")!
let art = NSBitmapImageRep(data: artwork.tiffRepresentation!)!
let w = art.pixelsWide, h = art.pixelsHigh

// Find the rounded square: the first and last non-black pixels along the middle row and column.
func lit(_ x: Int, _ y: Int) -> Bool { (art.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)?.brightnessComponent ?? 0) > 0.06 }
let left = (0..<w).first { lit($0, h / 2) }!, right = (0..<w).last { lit($0, h / 2) }!
let top = (0..<h).first { lit(w / 2, $0) }!, bottom = (0..<h).last { lit(w / 2, $0) }!
let crop = NSRect(x: left, y: h - 1 - bottom, width: right - left + 1, height: bottom - top + 1)  // AppKit counts from the bottom

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
// macOS icon grid: an 824-point rounded square centred on the 1024 canvas, with a soft shadow
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.shadowBlurRadius = 24
shadow.set()
NSColor.black.setFill()
shape.fill()
NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.saveGraphicsState()
shape.addClip()
NSImage(cgImage: art.cgImage!, size: NSSize(width: w, height: h))
    .draw(in: tile, from: crop, operation: .copy, fraction: 1)
NSGraphicsContext.restoreGraphicsState()
image.unlockFocus()
print("Artwork \(w)x\(h), rounded square found at x \(left)-\(right), y \(top)-\(bottom)")

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
