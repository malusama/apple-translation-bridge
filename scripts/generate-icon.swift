import AppKit
import Foundation

// Export the native Icon Composer document for legacy/static icon consumers.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let selection = Process()
selection.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
selection.arguments = ["-p"]
let output = Pipe(); selection.standardOutput = output
try selection.run(); selection.waitUntilExit()
let selected = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    .trimmingCharacters(in: .whitespacesAndNewlines)
let developer = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] ?? selected
let tool = URL(fileURLWithPath: developer).deletingLastPathComponent()
    .appendingPathComponent("Applications/Icon Composer.app/Contents/Executables/ictool")
let source = root.appendingPathComponent("assets/liquid-glass/default.png")
try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
let render = Process(); render.executableURL = tool
render.arguments = [root.appendingPathComponent("MacApp/AppIcon.icon").path,
                    "--export-image", "--output-file", source.path, "--platform", "macOS",
                    "--rendition", "Default", "--width", "1024", "--height", "1024",
                    "--scale", "1", "--design-generation", "27"]
try render.run(); render.waitUntilExit()
precondition(render.terminationStatus == 0, "Icon Composer render failed")
guard let artwork = NSImage(contentsOf: source) else {
    fatalError("Cannot load app icon artwork at \(source.path)")
}
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
        NSGraphicsContext.current!.imageInterpolation = .high
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        artwork.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024),
                     from: .zero, operation: .sourceOver, fraction: 1)
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
