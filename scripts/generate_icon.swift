import Cocoa

let iconsetPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/AppIcon.iconset"
let sourceLogoPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "BoFinderApp/AppLogo.png"

let fm = FileManager.default
try? fm.removeItem(atPath: iconsetPath)
try fm.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

let sourceImage = NSImage(contentsOfFile: sourceLogoPath)

func renderIcon(size: Int) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        img.unlockFocus()
        return img
    }

    ctx.interpolationQuality = .high
    let s = CGFloat(size)
    let pad = s * 0.06
    let rect = CGRect(x: pad, y: pad, width: s - pad * 2, height: s - pad * 2)
    let radius = rect.width * 0.225

    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    ctx.saveGState()
    path.addClip()

    if let src = sourceImage {
        src.draw(
            in: rect,
            from: NSRect(origin: .zero, size: src.size),
            operation: .sourceOver,
            fraction: 1.0
        )
    } else {
        NSColor.systemBlue.setFill()
        rect.fill()
    }

    ctx.restoreGState()
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
