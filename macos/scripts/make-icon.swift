// Renders the app icon into Resources/AppIcon.icns: swift scripts/make-icon.swift
import AppKit

func render(size: CGFloat) -> Data {
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        // Apple's icon grid: an 824/1024 rounded square centred on the canvas.
        let inset = rect.width * 100 / 1024
        let shape = rect.insetBy(dx: inset, dy: inset)
        let radius = shape.width * 0.225
        let path = NSBezierPath(roundedRect: shape, xRadius: radius, yRadius: radius)

        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowBlurRadius = rect.width * 0.02
        shadow.shadowOffset = NSSize(width: 0, height: -rect.width * 0.01)
        shadow.set()
        NSColor.white.setFill()
        path.fill()
        NSGraphicsContext.current?.restoreGraphicsState()

        NSGradient(colors: [
            NSColor(srgbRed: 0.36, green: 0.78, blue: 1.0, alpha: 1),
            NSColor(srgbRed: 0.0, green: 0.45, blue: 0.98, alpha: 1),
        ])!.draw(in: path, angle: -90)

        // Soft specular highlight across the top, as on glass icons.
        NSGraphicsContext.current?.saveGraphicsState()
        path.addClip()
        NSGradient(colors: [NSColor.white.withAlphaComponent(0.35), NSColor.white.withAlphaComponent(0)])!
            .draw(in: NSRect(x: shape.minX, y: shape.midY, width: shape.width, height: shape.height / 2), angle: -90)
        NSGraphicsContext.current?.restoreGraphicsState()

        let configuration = NSImage.SymbolConfiguration(pointSize: shape.width * 0.46, weight: .medium)
            .applying(.init(paletteColors: [.white, .white]))
        if let symbol = NSImage(systemSymbolName: "envelope.badge.shield.half.filled", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) {
            let symbolSize = symbol.size
            symbol.draw(in: NSRect(x: rect.midX - symbolSize.width / 2, y: rect.midY - symbolSize.height / 2,
                                   width: symbolSize.width, height: symbolSize.height))
        }
        return true
    }
    let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
    return bitmap.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = root.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try render(size: CGFloat(base * scale)).write(to: iconset.appendingPathComponent(name))
    }
}
