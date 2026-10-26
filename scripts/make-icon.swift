// Renders the app icon into an .iconset folder for `iconutil`.
// Usage: swift scripts/make-icon.swift <output.iconset>

import AppKit

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output.iconset>\n".utf8))
    exit(1)
}
let output = URL(filePath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

/// Draws the icon on a 1024-point canvas, following the macOS icon grid
/// (an 824-point rounded square, inset 100 points).
func drawIcon(in context: CGContext) {
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Drop shadow under the tile.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28,
                      color: NSColor.black.withAlphaComponent(0.3).cgColor)
    context.addPath(path)
    context.setFillColor(NSColor.black.cgColor)
    context.fillPath()
    context.restoreGState()

    // Background gradient.
    context.saveGState()
    context.addPath(path)
    context.clip()
    let colors = [
        NSColor(srgbRed: 0.22, green: 0.56, blue: 0.98, alpha: 1).cgColor,
        NSColor(srgbRed: 0.35, green: 0.27, blue: 0.86, alpha: 1).cgColor,
    ]
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: colors as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])
    context.restoreGState()

    // Two folders side by side, with a compare arrow between them.
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    func symbol(_ name: String, pointSize: CGFloat, color: NSColor, in rect: CGRect) {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }
        // Fit the symbol inside the rect, keeping its aspect ratio.
        let scale = min(rect.width / image.size.width, rect.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let origin = CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
        image.draw(in: CGRect(origin: origin, size: size))
    }

    symbol("folder.fill", pointSize: 300, color: .white, in: CGRect(x: 160, y: 400, width: 330, height: 280))
    symbol("folder.fill", pointSize: 300, color: NSColor.white.withAlphaComponent(0.75),
           in: CGRect(x: 534, y: 400, width: 330, height: 280))
    symbol("arrow.left.arrow.right", pointSize: 200, color: .white,
           in: CGRect(x: 362, y: 180, width: 300, height: 190))
}

let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for (name, pixels) in sizes {
    guard let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("couldn't create a \(pixels)px context") }
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    drawIcon(in: context)

    let png = NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
    try png.write(to: output.appendingPathComponent("\(name).png"))
}
