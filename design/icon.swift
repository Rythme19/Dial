// Draws Dial's app icon and writes AppIcon.icns to the project root.
//   swift design/icon.swift
import AppKit

let S: CGFloat = 1024
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: a)
}

// macOS icon grid: 824 pt tile centred on a 1024 canvas.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0, 0.35))
ctx.addPath(shape); ctx.setFillColor(rgb(0x0a7cff)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(shape); ctx.clip()
let bg = CGGradient(colorsSpace: nil, colors: [rgb(0x4fb0ff), rgb(0x0a7cff), rgb(0x0047c2)] as CFArray,
                    locations: [0, 0.5, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])

// The ring: six segments with even-width gaps, the top one lit like a chosen item.
let c = CGPoint(x: S / 2, y: S / 2), ro: CGFloat = 300, ri: CGFloat = 178, gap: CGFloat = 9
for i in 0..<6 {
    let mid = CGFloat.pi / 2 - CGFloat(i) * .pi / 3, half = CGFloat.pi / 6
    let p = CGMutablePath()
    p.addArc(center: c, radius: ro, startAngle: mid - half + gap / ro, endAngle: mid + half - gap / ro, clockwise: false)
    p.addArc(center: c, radius: ri, startAngle: mid + half - gap / ri, endAngle: mid - half + gap / ri, clockwise: true)
    p.closeSubpath()
    ctx.saveGState()
    if i == 0 { ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: rgb(0x002a80, 0.45)) }
    ctx.addPath(p); ctx.setFillColor(i == 0 ? rgb(0xffffff) : rgb(0xffffff, 0.26)); ctx.fillPath()
    ctx.restoreGState()
}

// Hub.
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: rgb(0x002a80, 0.4))
ctx.addEllipse(in: CGRect(x: c.x - 104, y: c.y - 104, width: 208, height: 208))
ctx.setFillColor(rgb(0xffffff, 0.94)); ctx.fillPath()
ctx.setShadow(offset: .zero, blur: 0, color: nil)
ctx.addEllipse(in: CGRect(x: c.x - 30, y: c.y - 30, width: 60, height: 60))
ctx.setFillColor(rgb(0x0a7cff)); ctx.fillPath()
ctx.restoreGState()

// Write every size into an iconset, then let iconutil pack it.
let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let set = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
let full = ctx.makeImage()!
for pt in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = pt * scale
        let small = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                              space: full.colorSpace!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        small.interpolationQuality = .high
        small.draw(full, in: CGRect(x: 0, y: 0, width: px, height: px))
        let rep = NSBitmapImageRep(cgImage: small.makeImage()!)
        let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
        try! rep.representation(using: .png, properties: [:])!.write(to: set.appendingPathComponent(name))
    }
}
let out = root.appendingPathComponent("AppIcon.icns").path
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", out]
try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "Wrote \(out)\nPreview: \(set.path)/icon_512x512@2x.png" : "iconutil failed")
