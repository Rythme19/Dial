// Draws the GitHub logo and social preview from AppIcon.icns.
//   swift design/social.swift   → docs/logo.png, docs/social-preview.png
import AppKit

let icon = NSImage(contentsOfFile: "AppIcon.icns")!

func png(_ w: Int, _ h: Int, _ path: String, _ draw: (CGRect) -> Void) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(CGRect(x: 0, y: 0, width: w, height: h))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

png(512, 512, "docs/logo.png") { icon.draw(in: $0) }

png(1280, 640, "docs/social-preview.png") { r in
    NSGradient(colors: [NSColor(srgbRed: 0.04, green: 0.06, blue: 0.13, alpha: 1),
                        NSColor(srgbRed: 0.02, green: 0.18, blue: 0.42, alpha: 1)])!.draw(in: r, angle: -30)
    icon.draw(in: CGRect(x: 90, y: 150, width: 340, height: 340))
    func text(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight, _ alpha: CGFloat, _ y: CGFloat) {
        NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: NSColor.white.withAlphaComponent(alpha),
        ]).draw(at: CGPoint(x: 480, y: y))
    }
    text("Dial", 128, .bold, 1, 330)
    text("Quick file actions for macOS Finder", 40, .medium, 0.92, 262)
    text("Tap ⌥ ⌘ to convert, merge and compress files.", 30, .regular, 0.62, 205)
}
