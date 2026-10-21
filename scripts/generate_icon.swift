import Cocoa

let iconsetPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/AppIcon.iconset"
let fm = FileManager.default
try? fm.removeItem(atPath: iconsetPath)
try fm.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

func renderIcon(size: Int) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        img.unlockFocus()
        return img
    }

    let s = CGFloat(size)
    let pad = s * 0.08
    let rect = CGRect(x: pad, y: pad, width: s - pad * 2, height: s - pad * 2)
    let radius = rect.width * 0.225

    // Background rounded squircle with blue-indigo gradient
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    ctx.saveGState()
    path.addClip()

    let colors = [
        NSColor(calibratedRed: 0.14, green: 0.52, blue: 0.98, alpha: 1.0).cgColor,
        NSColor(calibratedRed: 0.22, green: 0.25, blue: 0.86, alpha: 1.0).cgColor
    ] as CFArray
    let space = CGColorSpaceCreateDeviceRGB()
    if let grad = CGGradient(colorsSpace: space, colors: colors, locations: [0.0, 1.0]) {
        ctx.drawLinearGradient(
            grad,
            start: CGPoint(x: rect.minX, y: rect.maxY),
            end: CGPoint(x: rect.maxX, y: rect.minY),
            options: []
        )
    }
    ctx.restoreGState()

    // Draw SF Symbol in center
    if let sym = NSImage(systemSymbolName: "doc.on.clipboard.fill", accessibilityDescription: nil) {
        let config = NSImage.SymbolConfiguration(pointSize: s * 0.44, weight: .bold)
        if let configured = sym.withSymbolConfiguration(config) {
            let tinted = NSImage(size: configured.size)
            tinted.lockFocus()
            NSColor.white.set()
            let symRect = NSRect(origin: .zero, size: configured.size)
            configured.draw(in: symRect)
            symRect.fill(using: .sourceAtop)
            tinted.unlockFocus()

            let drawW = configured.size.width
            let drawH = configured.size.height
            let drawRect = NSRect(
                x: (s - drawW) / 2,
                y: (s - drawH) / 2,
                width: drawW,
                height: drawH
            )
            tinted.draw(in: drawRect)
        }
    }

    img.unlockFocus()
    return img
}

let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png")
]

for (px, filename) in sizes {
    let image = renderIcon(size: px)
    if let tiff = image.tiffRepresentation,
       let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) {
        let outURL = URL(fileURLWithPath: iconsetPath).appendingPathComponent(filename)
        try png.write(to: outURL)
    }
}
