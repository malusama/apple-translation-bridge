#!/usr/bin/env swift
import AppKit
import CoreText
import Foundation

// Original vector artwork. Icon Composer supplies the glass material and light.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let document = root.appendingPathComponent("MacApp/AppIcon.icon")
let assets = document.appendingPathComponent("Assets")
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

func glyphPath(_ text: String, fitting target: CGRect) -> String {
    let base = CTFontCreateWithName("HelveticaNeue-Medium" as CFString, 280, nil)
    let font = CTFontCreateForString(base, text as CFString, CFRange(location: 0, length: text.utf16.count))
    var character = Array(text.utf16)[0]
    var glyph: CGGlyph = 0
    precondition(CTFontGetGlyphsForCharacters(font, &character, &glyph, 1))
    guard let path = CTFontCreatePathForGlyph(font, glyph, nil) else { fatalError("Missing glyph: \(text)") }
    let bounds = path.boundingBoxOfPath
    let scale = min(target.width / bounds.width, target.height / bounds.height)
    var transform = CGAffineTransform(a: scale, b: 0, c: 0, d: -scale,
                                     tx: target.midX - bounds.midX * scale,
                                     ty: target.midY + bounds.midY * scale)
    let placed = path.copy(using: &transform)!
    var commands: [String] = []
    func point(_ p: CGPoint) -> String { String(format: "%.3f %.3f", p.x, p.y) }
    placed.applyWithBlock { item in
        let element = item.pointee
        switch element.type {
        case .moveToPoint: commands.append("M" + point(element.points[0]))
        case .addLineToPoint: commands.append("L" + point(element.points[0]))
        case .addQuadCurveToPoint: commands.append("Q" + point(element.points[0]) + " " + point(element.points[1]))
        case .addCurveToPoint: commands.append("C" + point(element.points[0]) + " " + point(element.points[1]) + " " + point(element.points[2]))
        case .closeSubpath: commands.append("Z")
        @unknown default: fatalError("Unknown path element")
        }
    }
    return commands.joined(separator: " ")
}

func svg(_ name: String, content: String) throws {
    let text = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1024\" height=\"1024\" viewBox=\"0 0 1024 1024\">\(content)</svg>\n"
    try Data(text.utf8).write(to: assets.appendingPathComponent(name + ".svg"))
}

try svg("English glass", content: "<rect x=\"198\" y=\"208\" width=\"414\" height=\"414\" rx=\"94\" fill=\"#008CFA\" fill-opacity=\"0.72\"/>")
try svg("Chinese glass", content: "<rect x=\"412\" y=\"402\" width=\"414\" height=\"414\" rx=\"94\" fill=\"#C9F4FF\" fill-opacity=\"0.60\"/>")
try svg("A", content: "<path d=\"\(glyphPath("A", fitting: CGRect(x: 285, y: 284, width: 236, height: 252)))\" fill=\"#F4FBFF\"/>")
try svg("Wen", content: "<path d=\"\(glyphPath("文", fitting: CGRect(x: 496, y: 488, width: 246, height: 246)))\" fill=\"#145ABC\"/>")

func group(_ name: String, depth: Double, transmission: Double, shadow: Double, isGlyph: Bool) -> [String: Any] {
    var layer: [String: Any] = ["name": name, "image-name": name + ".svg", "glass": true]
    if isGlyph {
        layer["fill-specializations"] = [["appearance": "dark", "value": "system-light"],
                                         ["appearance": "tinted", "value": "system-light"]]
    }
    return ["name": name, "layers": [layer], "lighting": "individual",
            "blur-material": isGlyph ? 0 : 0.035,
            "refractivity": ["enabled": true, "depth": depth, "strength": isGlyph ? 0.035 : 0.13],
            "shadow": ["kind": "neutral", "opacity": shadow], "specular": "outside",
            "translucency": ["enabled": true, "value": transmission]]
}

// Icon Composer orders foreground groups before background groups.
let icon: [String: Any] = [
    "features": ["refractivity", "specular-location"], "fill": "automatic",
    "groups": [group("Wen", depth: 0.018, transmission: 0.16, shadow: 0.015, isGlyph: true),
               group("Chinese glass", depth: 0.075, transmission: 0.82, shadow: 0.09, isGlyph: false),
               group("A", depth: 0.018, transmission: 0.10, shadow: 0.015, isGlyph: true),
               group("English glass", depth: 0.085, transmission: 0.72, shadow: 0.10, isGlyph: false)],
    "supported-platforms": ["squares": "shared"]
]
try JSONSerialization.data(withJSONObject: icon, options: [.prettyPrinted, .sortedKeys])
    .write(to: document.appendingPathComponent("icon.json"))
print("Created original layered artwork at \(document.path)")
