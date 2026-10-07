import AppKit
import Foundation

// Original app artwork, drawn with AppKit so every size can be regenerated.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let directory = root.appendingPathComponent("MacApp/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)

        let base = NSBezierPath(roundedRect: NSRect(x: 48, y: 48, width: 928, height: 928), xRadius: 205, yRadius: 205)
        NSGradient(starting: NSColor(red: 0.19, green: 0.57, blue: 0.98, alpha: 1),
                   ending: NSColor(red: 0.08, green: 0.28, blue: 0.79, alpha: 1))!.draw(in: base, angle: -90)
        func bubble(_ rect: NSRect, tailLeft: Bool, opacity: CGFloat) {
            let shape = NSBezierPath(roundedRect: rect, xRadius: 65, yRadius: 65)
            let tail = NSBezierPath()
            let x = tailLeft ? rect.minX + 60 : rect.maxX - 60
            tail.move(to: NSPoint(x: x, y: rect.minY + 25))
            tail.line(to: NSPoint(x: x, y: rect.minY - 55))
            tail.line(to: NSPoint(x: x + (tailLeft ? 100 : -100), y: rect.minY + 25))
            tail.close()
            NSColor.white.withAlphaComponent(opacity).setFill(); shape.fill(); tail.fill()
        }
        bubble(NSRect(x: 165, y: 445, width: 390, height: 330), tailLeft: true, opacity: 0.90)
        bubble(NSRect(x: 475, y: 270, width: 385, height: 330), tailLeft: false, opacity: 1)
        let ink = NSColor(red: 0.08, green: 0.30, blue: 0.70, alpha: 1)
        let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 240, weight: .semibold), .foregroundColor: ink]
        ("A" as NSString).draw(at: NSPoint(x: 275, y: 455), withAttributes: a)
        let chinese: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 225, weight: .medium), .foregroundColor: ink]
        ("译" as NSString).draw(at: NSPoint(x: 550, y: 288), withAttributes: chinese)
        NSGraphicsContext.restoreGraphicsState()
        let filename = "icon_\(points)x\(points)@\(scale)x.png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(filename))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": filename])
    }
}
let manifest: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("Contents.json"))
let assets = directory.deletingLastPathComponent().appendingPathComponent("Contents.json")
try Data(#"{"info":{"author":"xcode","version":1}}"#.utf8).write(to: assets)
