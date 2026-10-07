#!/usr/bin/env swift
import CoreImage
import Foundation
import ImageIO

// Author a short HDR reflection on the native glass rim, retaining the SDR base.
// Usage: swift scripts/export-icon-hdr.swift <Icon Composer PNG> <output dir> <light|dark>
enum ExportError: Error { case usage, invalidInput, colorSpace, decodeFailure, missingHDR(String) }
guard CommandLine.arguments.count == 4,
      ["light", "dark"].contains(CommandLine.arguments[3]) else { throw ExportError.usage }
let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let appearance = CommandLine.arguments[3]
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
guard let source = CIImage(contentsOf: inputURL),
      let linear = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3),
      let p3 = CGColorSpace(name: CGColorSpace.displayP3) else { throw ExportError.invalidInput }
let background = CIImage(color: appearance == "light" ? .white : .black).cropped(to: source.extent)
let input = source.composited(over: background)
let context = CIContext(options: [.workingColorSpace: linear, .workingFormat: CIFormat.RGBAf])
let width = Int(input.extent.width), height = Int(input.extent.height)
let count = width * height
var pixels = [Float](repeating: 0, count: count * 4)
pixels.withUnsafeMutableBytes { data in
    context.render(input, toBitmap: data.baseAddress!, rowBytes: width * 16,
                   bounds: input.extent, format: .RGBAf, colorSpace: linear)
}

var reflection = [Float](repeating: 0, count: count)
for row in 0..<height {
    for column in 0..<width {
        let offset = (row * width + column) * 4
        let x = (Float(column) + 0.5) / Float(width)
        let y = (Float(row) + 0.5) / Float(height)
        let dx = (x - 0.375) / 0.072, dy = (y - 0.205) / 0.008
        let distance = dx * dx + dy * dy
        guard distance < 1 else { continue }
        let red = pixels[offset], green = pixels[offset + 1], blue = pixels[offset + 2]
        guard blue - red > 0.10 else { continue }
        let threshold: Float = appearance == "light" ? 0.30 : 0.075
        let span: Float = appearance == "light" ? 0.40 : 0.16
        let brightness = max(0, min(1, (green - threshold) / span))
        let smooth = brightness * brightness * (3 - 2 * brightness)
        reflection[row * width + column] = (1 - distance) * (1 - distance) * smooth
    }
}

var maskPixels = [Float](repeating: 0, count: count * 4)
var peak: Float = 1
var boosted = 0
for row in 0..<height {
    for column in 0..<width {
        let offset = (row * width + column) * 4
        var mask: Float = 0
        if pixels[offset + 2] - pixels[offset] > 0.10 {
            for dy in -3...3 {
                for dx in -3...3 where dx * dx + dy * dy <= 9 {
                    let x = column + dx, y = row + dy
                    guard (0..<width).contains(x), (0..<height).contains(y) else { continue }
                    mask = max(mask, reflection[y * width + x] * (1 - Float(dx * dx + dy * dy) / 16))
                }
            }
        }
        for channel in 0..<3 {
            pixels[offset + channel] += 2.5 * mask
            peak = max(peak, pixels[offset + channel])
            maskPixels[offset + channel] = mask
        }
        maskPixels[offset + 3] = 1
        if mask > 0.01 { boosted += 1 }
    }
}
func image(_ values: [Float]) -> CIImage {
    CIImage(bitmapData: values.withUnsafeBytes { Data($0) }, bytesPerRow: width * 16,
            size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: linear)
}
let hdr = image(pixels).settingContentHeadroom(peak)
let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
let encodeOptions = CIImageRepresentationOption(rawValue: kCGImageDestinationEncodeRequestOptions as String)
let options: [CIImageRepresentationOption: Any] = [
    .hdrImage: hdr, .hdrGainMapAsRGB: true, quality: 1,
    encodeOptions: [kCGImageDestinationEncodeGainMapSubsampleFactor as String: 1]
]
let prefix = "icon-\(appearance)-hdr"
try context.writeHEIFRepresentation(of: input, to: directory.appendingPathComponent(prefix + ".heic"),
                                   format: .RGBA8, colorSpace: p3, options: options)
try context.writeJPEGRepresentation(of: input, to: directory.appendingPathComponent(prefix + ".jpg"),
                                    colorSpace: p3, options: options)
try context.writePNGRepresentation(of: image(maskPixels), to: directory.appendingPathComponent("highlight-mask-\(appearance).png"),
                                   format: .RGBA8, colorSpace: p3)

var report: [String: Any] = [
    "method": "Native Icon Composer render plus one authored neutral reflection; Core Image Adaptive HDR",
    "appearance": appearance, "width": width, "height": height,
    "authoredPeakRelativeToSDRWhite": peak,
    "boostedPixelFraction": Double(boosted) / Double(count),
    "highlightCenterNormalizedTopLeft": [0.375, 0.205],
    "note": "The gain-map assets enable HDR in the app header and design previews. Dock rendering is supplied by the layered system icon."
]
for suffix in ["heic", "jpg"] {
    let file = prefix + "." + suffix
    let url = directory.appendingPathComponent(file)
    guard let decoded = CIImage(contentsOf: url, options: [.expandToHDR: true]),
          let encoded = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw ExportError.decodeFailure }
    let isoMap = CGImageSourceCopyAuxiliaryDataInfoAtIndex(encoded, 0, kCGImageAuxiliaryDataTypeISOGainMap)
    let appleMap = CGImageSourceCopyAuxiliaryDataInfoAtIndex(encoded, 0, kCGImageAuxiliaryDataTypeHDRGainMap)
    var decodedPixels = [Float](repeating: 0, count: count * 4)
    decodedPixels.withUnsafeMutableBytes { bytes in
        context.render(decoded, toBitmap: bytes.baseAddress!, rowBytes: width * 16,
                       bounds: decoded.extent, format: .RGBAf, colorSpace: linear)
    }
    let decodedPeak = decodedPixels.enumerated().filter { $0.offset % 4 != 3 }.map(\.element).max() ?? 0
    guard isoMap != nil || appleMap != nil, decoded.contentHeadroom > 1.5, decodedPeak > 1.5 else {
        throw ExportError.missingHDR("\(file): peak=\(decodedPeak), headroom=\(decoded.contentHeadroom), authored=\(peak)")
    }
    report[file] = ["contentHeadroom": decoded.contentHeadroom, "decodedPeakLinearP3": decodedPeak,
                    "isoGainMapPresent": isoMap != nil, "appleGainMapPresent": appleMap != nil]
}
let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
try data.write(to: directory.appendingPathComponent("hdr-verification-\(appearance).json"))
print(String(decoding: data, as: UTF8.self))
