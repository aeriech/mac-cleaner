// Renders the Mac Cleaner app icon (1024×1024 PNG) with Core Graphics.
// Usage: make_icon <out.png>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Four-point sparkle with concave sides.
func sparkle(_ c: CGPoint, _ r: CGFloat) -> CGPath {
    let tips = [CGPoint(x: c.x, y: c.y + r), CGPoint(x: c.x + r, y: c.y),
                CGPoint(x: c.x, y: c.y - r), CGPoint(x: c.x - r, y: c.y)]
    let path = CGMutablePath()
    path.move(to: tips[0])
    for i in 0..<4 {
        let a = tips[i], b = tips[(i + 1) % 4]
        let pull: CGFloat = 0.16   // control point near the centre pulls each side inward
        path.addQuadCurve(to: b, control: CGPoint(x: c.x + (a.x + b.x - 2 * c.x) * pull,
                                                  y: c.y + (a.y + b.y - 2 * c.y) * pull))
    }
    path.closeSubpath()
    return path
}

// macOS icon grid: 824pt rounded square centred on a 1024 canvas.
let tile = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
                  cornerWidth: 186, cornerHeight: 186, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.32))
ctx.addPath(tile); ctx.setFillColor(rgb(0x2F5BFF)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tile); ctx.clip()
let body = CGGradient(colorsSpace: space, colors: [rgb(0x6A3DF5), rgb(0x2E6BFF), rgb(0x12CFC0)] as CFArray,
                      locations: [0, 0.52, 1])!
ctx.drawLinearGradient(body, start: CGPoint(x: 140, y: 930), end: CGPoint(x: 900, y: 90), options: [])
let gloss = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0.20), rgb(0xFFFFFF, 0)] as CFArray,
                       locations: [0, 1])!
ctx.drawLinearGradient(gloss, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 540), options: [])
ctx.restoreGState()

// Gauge ring: faint track plus a bright 3/4 arc, echoing the in-app "space to clean" ring.
let centre = CGPoint(x: 512, y: 512)
ctx.setLineCap(.round)
ctx.setLineWidth(56)
ctx.setStrokeColor(rgb(0xFFFFFF, 0.22))
ctx.addArc(center: centre, radius: 262, startAngle: 0, endAngle: .pi * 2, clockwise: false)
ctx.strokePath()
ctx.setStrokeColor(rgb(0xFFFFFF, 0.97))
ctx.addArc(center: centre, radius: 262, startAngle: .pi / 2, endAngle: -.pi, clockwise: true)
ctx.strokePath()

// Sparkles.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: rgb(0x0A1A5C, 0.28))
ctx.setFillColor(rgb(0xFFFFFF))
ctx.addPath(sparkle(CGPoint(x: 492, y: 492), 150)); ctx.fillPath()
ctx.addPath(sparkle(CGPoint(x: 622, y: 628), 58)); ctx.fillPath()
ctx.setFillColor(rgb(0xFFFFFF, 0.85))
ctx.addPath(sparkle(CGPoint(x: 612, y: 372), 34)); ctx.fillPath()
ctx.restoreGState()

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "icon_1024.png")
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(out.path)") }
