// Triage app icon source. Drawn with Core Graphics on the macOS icon grid:
// an 824-point continuous-corner tile centered on a 1024 canvas, with a
// soft drop shadow.
import AppKit
import CoreGraphics

let canvas: CGFloat = 1024
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

/// Apple-style continuous-corner squircle (superellipse blend).
func squircle(_ r: CGRect, radius: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let k: CGFloat = 1.18
    let c = radius * k
    let (minX, minY, maxX, maxY) = (r.minX, r.minY, r.maxX, r.maxY)
    p.move(to: CGPoint(x: minX + c, y: minY))
    p.addLine(to: CGPoint(x: maxX - c, y: minY))
    p.addCurve(to: CGPoint(x: maxX, y: minY + c), control1: CGPoint(x: maxX - c * 0.22, y: minY), control2: CGPoint(x: maxX, y: minY + c * 0.22))
    p.addLine(to: CGPoint(x: maxX, y: maxY - c))
    p.addCurve(to: CGPoint(x: maxX - c, y: maxY), control1: CGPoint(x: maxX, y: maxY - c * 0.22), control2: CGPoint(x: maxX - c * 0.22, y: maxY))
    p.addLine(to: CGPoint(x: minX + c, y: maxY))
    p.addCurve(to: CGPoint(x: minX, y: maxY - c), control1: CGPoint(x: minX + c * 0.22, y: maxY), control2: CGPoint(x: minX, y: maxY - c * 0.22))
    p.addLine(to: CGPoint(x: minX, y: minY + c))
    p.addCurve(to: CGPoint(x: minX + c, y: minY), control1: CGPoint(x: minX, y: minY + c * 0.22), control2: CGPoint(x: minX + c * 0.22, y: minY))
    p.closeSubpath()
    return p
}

func linear(_ ctx: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func radial(_ ctx: CGContext, _ colors: [CGColor], center: CGPoint, radius: CGFloat) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
    ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
}

func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath { CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil) }

/// Base tile: drop shadow, gradient fill, top sheen, inner edge.
func base(_ ctx: CGContext, top: UInt32, bottom: UInt32, glow: UInt32? = nil) {
    let path = squircle(tile, radius: 185)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(path); ctx.setFillColor(color(bottom)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    linear(ctx, [color(top), color(bottom)], from: CGPoint(x: 512, y: tile.maxY), to: CGPoint(x: 512, y: tile.minY))
    if let glow { radial(ctx, [color(glow, 0.55), color(glow, 0)], center: CGPoint(x: 330, y: 760), radius: 560) }
    // sheen
    linear(ctx, [color(0xFFFFFF, 0.16), color(0xFFFFFF, 0)], from: CGPoint(x: 512, y: tile.maxY), to: CGPoint(x: 512, y: 560))
    ctx.restoreGState()
    // inner edge highlight
    ctx.saveGState()
    ctx.addPath(path); ctx.setStrokeColor(color(0xFFFFFF, 0.18)); ctx.setLineWidth(3); ctx.strokePath()
    ctx.restoreGState()
}

/// A four-point sparkle centered at c.
func sparkle(_ ctx: CGContext, _ c: CGPoint, _ size: CGFloat, fill: CGColor) {
    let p = CGMutablePath()
    let s = size, w = size * 0.28
    p.move(to: CGPoint(x: c.x, y: c.y + s))
    p.addQuadCurve(to: CGPoint(x: c.x + s, y: c.y), control: CGPoint(x: c.x + w, y: c.y + w))
    p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - s), control: CGPoint(x: c.x + w, y: c.y - w))
    p.addQuadCurve(to: CGPoint(x: c.x - s, y: c.y), control: CGPoint(x: c.x - w, y: c.y - w))
    p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + s), control: CGPoint(x: c.x - w, y: c.y + w))
    ctx.addPath(p); ctx.setFillColor(fill); ctx.fillPath()
}

/// A card with a soft shadow and vertical gradient.
func card(_ ctx: CGContext, _ r: CGRect, radius: CGFloat, top: CGColor, bottom: CGColor, shadow: CGFloat = 0.28) {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0x0A1240, shadow))
    ctx.addPath(rounded(r, radius)); ctx.setFillColor(bottom); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(rounded(r, radius)); ctx.clip()
    linear(ctx, [top, bottom], from: CGPoint(x: r.midX, y: r.maxY), to: CGPoint(x: r.midX, y: r.minY))
    ctx.restoreGState()
}

func bar(_ ctx: CGContext, _ r: CGRect, _ c: CGColor) {
    ctx.addPath(rounded(r, r.height / 2)); ctx.setFillColor(c); ctx.fillPath()
}

func dot(_ ctx: CGContext, _ center: CGPoint, _ radius: CGFloat, _ c: CGColor) {
    ctx.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    ctx.setFillColor(c); ctx.fillPath()
}

/// Triage's icon: a prioritized stack of work, the front item flagged, with a Copilot sparkle.
func appIcon(_ ctx: CGContext) {
    base(ctx, top: 0x4F7BFF, bottom: 0x1C2F9E, glow: 0x8FB4FF)
    let w: CGFloat = 520, h: CGFloat = 300
    card(ctx, CGRect(x: 512 - w / 2 + 70, y: 470, width: w - 140, height: h), radius: 54, top: color(0xB9C8FF, 0.75), bottom: color(0x8EA4F5, 0.75))
    card(ctx, CGRect(x: 512 - w / 2 + 35, y: 420, width: w - 70, height: h), radius: 56, top: color(0xDCE4FF, 0.9), bottom: color(0xB4C3FA, 0.9))
    let front = CGRect(x: 512 - w / 2, y: 290, width: w, height: h + 20)
    card(ctx, front, radius: 60, top: color(0xFFFFFF), bottom: color(0xE8EDFF), shadow: 0.4)
    dot(ctx, CGPoint(x: front.minX + 82, y: front.maxY - 88), 26, color(0xFF7A1A))
    bar(ctx, CGRect(x: front.minX + 132, y: front.maxY - 108, width: 280, height: 40), color(0x1E2B6B))
    bar(ctx, CGRect(x: front.minX + 132, y: front.maxY - 176, width: 220, height: 30), color(0x8A97C9))
    bar(ctx, CGRect(x: front.minX + 132, y: front.maxY - 230, width: 160, height: 30), color(0xB9C2E6))
    ctx.saveGState()
    radial(ctx, [color(0xFFFFFF, 0.35), color(0xFFFFFF, 0)], center: CGPoint(x: 772, y: 762), radius: 115)
    ctx.restoreGState()
    sparkle(ctx, CGPoint(x: 772, y: 762), 64, fill: color(0xFFFFFF))
}


// Renders Design/AppIcon-1024.png and every size in the app's asset catalog.
// Run from the repository root: swift Design/AppIcon.swift
let context = CGContext(data: nil, width: Int(canvas), height: Int(canvas), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
appIcon(context)
let master = context.makeImage()!

func write(_ image: CGImage, size: Int, to path: String) {
    let scaled = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                           space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    scaled.interpolationQuality = .high
    scaled.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    let rep = NSBitmapImageRep(cgImage: scaled.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

write(master, size: 1024, to: "Design/AppIcon-1024.png")
let set = "Triage/Assets.xcassets/AppIcon.appiconset"
for points in [16, 32, 128, 256, 512] {
    write(master, size: points, to: "\(set)/icon_\(points)x\(points).png")
    write(master, size: points * 2, to: "\(set)/icon_\(points)x\(points)@2x.png")
}
print("Rendered AppIcon")
