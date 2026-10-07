import AppKit
import SwiftUI

struct BrandIconView: View {
    @Environment(\.colorScheme) private var colorScheme

    private static let light = load("BrandIcon-Light", extension: "heic")
    private static let dark = load("BrandIcon-Dark", extension: "heic")
    private static let mask = load("BrandIconMask", extension: "png")

    private static func load(_ name: String, extension suffix: String) -> NSImage {
        guard let url = Bundle.main.url(forResource: name, withExtension: suffix),
              let image = NSImage(contentsOf: url) else { return NSApplication.shared.applicationIconImage }
        return image
    }

    var body: some View {
        Image(nsImage: colorScheme == .dark ? Self.dark : Self.light)
            .allowedDynamicRange(.high)
            .resizable().interpolation(.high).scaledToFit()
            .mask {
                Image(nsImage: Self.mask).resizable().interpolation(.high).scaledToFit()
            }
    }
}
