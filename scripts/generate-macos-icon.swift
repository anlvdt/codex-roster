import AppKit
import Foundation

let outputPath = CommandLine.arguments.dropFirst().first ?? "assets/codex-roster.png"
let canvasSize = NSSize(width: 1024, height: 1024)
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(canvasSize.width),
    pixelsHigh: Int(canvasSize.height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bitmapFormat: [],
    bytesPerRow: 0,
    bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fatalError("Could not create the macOS app icon canvas.")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
defer { NSGraphicsContext.restoreGraphicsState() }

let bounds = NSRect(origin: .zero, size: canvasSize)
NSGradient(
    starting: NSColor(calibratedRed: 0.06, green: 0.28, blue: 0.76, alpha: 1),
    ending: NSColor(calibratedRed: 0.12, green: 0.54, blue: 1, alpha: 1)
)?.draw(in: bounds, angle: -45)

let glow = NSBezierPath(ovalIn: NSRect(x: 116, y: 116, width: 792, height: 792))
NSColor.white.withAlphaComponent(0.12).setStroke()
glow.lineWidth = 34
glow.stroke()

let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 460, weight: .semibold)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
if let symbol = NSImage(systemSymbolName: "person.3.sequence.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(symbolConfiguration) {
    let size = symbol.size
    let rect = NSRect(
        x: (canvasSize.width - size.width) / 2,
        y: (canvasSize.height - size.height) / 2,
        width: size.width,
        height: size.height
    )
    symbol.draw(in: rect)
}

guard let png = bitmap.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) else {
    fatalError("Could not render the macOS app icon.")
}
try png.write(to: URL(fileURLWithPath: outputPath))
