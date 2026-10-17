// Draws the app icon and writes <out>/AppIcon.icns: the notch, open with two lines of session, and Clawd
// under it typing on his laptop (a frame of the "laptop" animation, cell by cell). Drawn on a 1024
// canvas in SVG-style coordinates (y down); the squircle fills 824 of it, as macOS icons do.
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let iconset = URL(fileURLWithPath: out).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

// o = clay, d = his shaded side, k = eye, g = laptop.
let clawd = [
    ".ddddoooooooooooo............",
    ".ddddoooooooooooo............",
    ".ddddoooooooooooo............",
    ".ddddookkooooookk............",
    ".ddddookkooooookk............",
    ".ddddoooooooooooo............",
    ".ddddooooooooooooooo.........",
    ".ddddoooooooooooooood......g.",
    ".ddddoooooooooooooood.....gg.",
    ".ddddoooooooooooooood....gg..",
    ".ddddoooooooooooodddd...gg...",
    ".dd..oo....oo..oo......gg....",
    "ddd.ooo...ooo.ooo.gggggg.....",
    "dd..oo....oo..oo.............",
]
let pixel: [Character: CGColor] = ["o": rgb(0xd97757), "d": rgb(0xbe684d), "k": rgb(0x0b0a09), "g": rgb(0xa29f97)]

/// macOS-style squircle: a superellipse (n = 5) of radius 412 around the canvas centre.
let squircle: CGPath = {
    let path = CGMutablePath()
    let c: CGFloat = 512, r: CGFloat = 412, n: CGFloat = 5
    for i in 0..<720 {
        let t = CGFloat(i) / 720 * 2 * .pi
        let ct = cos(t), st = sin(t)
        let p = CGPoint(x: c + r * (ct < 0 ? -1 : 1) * pow(abs(ct), 2 / n),
                        y: c + r * (st < 0 ? -1 : 1) * pow(abs(st), 2 / n))
        i == 0 ? path.move(to: p) : path.addLine(to: p)
    }
    path.closeSubpath()
    return path
}()

func draw(_ ctx: CGContext) {
    // Ground: warm charcoal, lighter at the top.
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let ground = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [rgb(0x2b2825), rgb(0x110f0e)] as CFArray,
                            locations: [0, 1])!
    ctx.drawLinearGradient(ground, start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 924), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    // The notch, hanging from the top edge, with two lines of session in it.
    let notch = CGMutablePath()
    notch.move(to: CGPoint(x: 252, y: 80))
    notch.addLine(to: CGPoint(x: 772, y: 80))
    notch.addLine(to: CGPoint(x: 772, y: 214))
    notch.addArc(tangent1End: CGPoint(x: 772, y: 290), tangent2End: CGPoint(x: 696, y: 290), radius: 76)
    notch.addLine(to: CGPoint(x: 328, y: 290))
    notch.addArc(tangent1End: CGPoint(x: 252, y: 290), tangent2End: CGPoint(x: 252, y: 214), radius: 76)
    notch.closeSubpath()
    ctx.addPath(notch)
    ctx.setFillColor(rgb(0x000000))
    ctx.fillPath()
    ctx.addPath(CGPath(roundedRect: CGRect(x: 318, y: 157, width: 310, height: 30), cornerWidth: 15, cornerHeight: 15, transform: nil))
    ctx.setFillColor(rgb(0xfaf9f5, 0.92))
    ctx.fillPath()
    ctx.addPath(CGPath(roundedRect: CGRect(x: 318, y: 203, width: 178, height: 30), cornerWidth: 15, cornerHeight: 15, transform: nil))
    ctx.setFillColor(rgb(0xfaf9f5, 0.38))
    ctx.fillPath()

    // His shadow, then Clawd.
    ctx.setFillColor(rgb(0x000000, 0.45))
    ctx.fillEllipse(in: CGRect(x: 502 - 310, y: 762 - 30, width: 620, height: 60))
    let cell: CGFloat = 20, x0: CGFloat = 242, y0: CGFloat = 470
    // One shape per colour, so neighbouring cells don't show seams between them.
    for (ch, color) in pixel {
        let shape = CGMutablePath()
        for (y, row) in clawd.enumerated() {
            for (x, c) in row.enumerated() where c == ch {
                shape.addRect(CGRect(x: x0 + CGFloat(x) * cell, y: y0 + CGFloat(y) * cell, width: cell + 0.6, height: cell + 0.6))
            }
        }
        ctx.addPath(shape)
        ctx.setFillColor(color)
        ctx.fillPath()
    }
    ctx.restoreGState()

    // A faint edge, so it holds up on a dark Dock.
    ctx.addPath(squircle)
    ctx.setStrokeColor(rgb(0xffffff, 0.08))
    ctx.setLineWidth(3)
    ctx.strokePath()
}

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    let ctx = context.cgContext
    // Map the 1024 canvas (y down) onto the bitmap (y up).
    let s = CGFloat(px) / 1024
    ctx.translateBy(x: 0, y: CGFloat(px))
    ctx.scaleBy(x: s, y: -s)
    // Crisp pixel edges for Clawd at small sizes.
    ctx.interpolationQuality = .none
    draw(ctx)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", URL(fileURLWithPath: out).appendingPathComponent("AppIcon.icns").path]
try task.run()
task.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
