// Turns the Clawd GIFs and the laptop Lottie in assets/clawd into small sprite sheets the app plays:
// Resources/clawd/<name>.png (frames side by side) plus Resources/clawd/sprites.json (sizes and timing).
// Each animation is cropped to Clawd himself and scaled to 128px tall.
//   swift scripts/make-sprites.swift
import AppKit
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let source = root.appendingPathComponent("assets/clawd")
let output = root.appendingPathComponent("Resources/clawd")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let height = 128.0
let space = CGColorSpace(name: CGColorSpace.sRGB)!

struct Entry: Codable {
    let frames: Int
    let width: Int
    let height: Int
    let delays: [Double]
    let loops: Bool
}

func context(_ w: Int, _ h: Int) -> CGContext {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

/// Bounding box (in the image's own pixels, top-left origin) of everything that isn't transparent.
func opaqueBounds(_ image: CGImage) -> CGRect? {
    let scale = 0.25
    let w = max(1, Int(Double(image.width) * scale)), h = max(1, Int(Double(image.height) * scale))
    let ctx = context(w, h)
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
    var minX = w, minY = h, maxX = -1, maxY = -1
    for y in 0..<h {
        for x in 0..<w where data[y * ctx.bytesPerRow + x * 4 + 3] > 8 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    guard maxX >= 0 else { return nil }
    // A bitmap context stores its top row first, so rows already count from the top.
    return CGRect(x: Double(minX) / scale, y: Double(minY) / scale,
                  width: Double(maxX - minX + 1) / scale, height: Double(maxY - minY + 1) / scale)
}

func writeSheet(_ name: String, frames: [CGImage], delays: [Double], loops: Bool, manifest: inout [String: Entry]) throws {
    let w = frames[0].width, h = frames[0].height
    let sheet = context(w * frames.count, h)
    for (i, frame) in frames.enumerated() { sheet.draw(frame, in: CGRect(x: i * w, y: 0, width: w, height: h)) }
    let url = output.appendingPathComponent("\(name).png")
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, sheet.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
    manifest[name] = Entry(frames: frames.count, width: w, height: h, delays: delays, loops: loops)
    print("\(name): \(frames.count) frames, \(w)x\(h)")
}

/// Crops every frame to `box` (top-left origin, source pixels) and scales it to `height`.
func cropAndScale(_ frames: [CGImage], to box: CGRect) -> [CGImage] {
    let scale = height / box.height
    let w = Int((box.width * scale).rounded()), h = Int(height)
    return frames.map { frame in
        let ctx = context(w, h)
        ctx.interpolationQuality = .high
        // Place the frame so that `box` fills the context (CG origin is bottom-left).
        let fullH = Double(frame.height) * scale
        ctx.draw(frame, in: CGRect(x: -box.minX * scale, y: -(Double(frame.height) - box.maxY) * scale,
                                   width: Double(frame.width) * scale, height: fullH))
        return ctx.makeImage()!
    }
}

var manifest: [String: Entry] = [:]

// MARK: GIFs

let gifs: [(file: String, name: String, loops: Bool)] = [
    ("Clawd-Lurking.gif", "lurking", true),
    ("Clawd-JumpingHappy.gif", "jumping", true),
    ("Clawd-Waving.gif", "waving", true),
    ("Clawd-CrabWalking.gif", "crab", true),
    ("Clawd-Dancing.gif", "dancing", true),
    ("Clawd-RacingCar.gif", "racing", true),
    ("Clawd-Cloud-once.gif", "cloud", false),
]
for gif in gifs {
    let src = CGImageSourceCreateWithURL(source.appendingPathComponent(gif.file) as CFURL, nil)!
    var frames: [CGImage] = [], delays: [Double] = []
    for i in 0..<CGImageSourceGetCount(src) {
        frames.append(CGImageSourceCreateImageAtIndex(src, i, nil)!)
        let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [String: Any]
        let g = props?[kCGImagePropertyGIFDictionary as String] as? [String: Any]
        let delay = (g?[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double) ?? (g?[kCGImagePropertyGIFDelayTime as String] as? Double) ?? 0.1
        delays.append(delay < 0.02 ? 0.1 : delay)
    }
    let box = frames.compactMap(opaqueBounds).reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -8, dy: -8)
    try writeSheet(gif.name, frames: cropAndScale(frames, to: box), delays: delays, loops: gif.loops, manifest: &manifest)
}

// MARK: Lottie (laptop)
// The file is pixel art: groups of straight-edged paths whose fill opacity switches per frame (hold keys).

let lottie = try JSONSerialization.jsonObject(with: Data(contentsOf: source.appendingPathComponent("clawd-laptop.json"))) as! [String: Any]
let canvasW = lottie["w"] as! Double, canvasH = lottie["h"] as! Double
let frameCount = Int((lottie["op"] as! Double) - (lottie["ip"] as! Double))
let fps = lottie["fr"] as! Double

func value(_ prop: [String: Any], at t: Double) -> [Double] {
    if (prop["a"] as? Int) == 1, let keys = prop["k"] as? [[String: Any]] {
        let current = keys.last { ($0["t"] as! Double) <= t } ?? keys[0]
        return current["s"] as! [Double]
    }
    if let k = prop["k"] as? [Double] { return k }
    if let k = prop["k"] as? Double { return [k] }
    return []
}

func renderLottie(frame t: Double, into ctx: CGContext, scale: Double, offset: CGPoint) {
    ctx.saveGState()
    // Lottie coordinates: top-left origin, y down.
    ctx.translateBy(x: 0, y: CGFloat(ctx.height))
    ctx.scaleBy(x: scale, y: -scale)
    ctx.translateBy(x: -offset.x, y: -offset.y)
    for layer in (lottie["layers"] as! [[String: Any]]).reversed() {
        for group in (layer["shapes"] as? [[String: Any]] ?? []).reversed() where group["ty"] as? String == "gr" {
            let items = group["it"] as! [[String: Any]]
            guard let fill = items.first(where: { $0["ty"] as? String == "fl" }) else { continue }
            let opacity = (value(fill["o"] as! [String: Any], at: t).first ?? 100) / 100
            guard opacity > 0 else { continue }
            let c = value(fill["c"] as! [String: Any], at: t)
            let path = CGMutablePath()
            for item in items where item["ty"] as? String == "sh" {
                let shape = (item["ks"] as! [String: Any])["k"] as! [String: Any]
                let v = shape["v"] as! [[Double]]
                guard let first = v.first else { continue }
                path.move(to: CGPoint(x: first[0], y: first[1]))
                for p in v.dropFirst() { path.addLine(to: CGPoint(x: p[0], y: p[1])) }
                if shape["c"] as? Bool == true { path.closeSubpath() }
            }
            ctx.setFillColor(CGColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: (c.count > 3 ? c[3] : 1) * opacity))
            ctx.addPath(path)
            ctx.fillPath(using: (fill["r"] as? Int) == 2 ? .evenOdd : .winding)
        }
    }
    ctx.restoreGState()
}

// Find the bounds over all frames at low resolution, then render each frame cropped and sharp.
let probeScale = 0.25
var box = CGRect.null
for t in 0..<frameCount {
    let probe = context(Int(canvasW * probeScale), Int(canvasH * probeScale))
    renderLottie(frame: Double(t), into: probe, scale: probeScale, offset: .zero)
    if let b = opaqueBounds(probe.makeImage()!) { box = box.union(CGRect(x: b.minX / probeScale, y: b.minY / probeScale, width: b.width / probeScale, height: b.height / probeScale)) }
}
box = box.insetBy(dx: -40, dy: -40)
let lottieScale = height / box.height
var laptopFrames: [CGImage] = []
for t in 0..<frameCount {
    let ctx = context(Int((box.width * lottieScale).rounded()), Int(height))
    renderLottie(frame: Double(t), into: ctx, scale: lottieScale, offset: box.origin)
    laptopFrames.append(ctx.makeImage()!)
}
try writeSheet("laptop", frames: laptopFrames, delays: Array(repeating: 1 / fps, count: frameCount), loops: true, manifest: &manifest)

// MARK: Still

if let still = NSImage(contentsOf: source.appendingPathComponent("Clawd-Cloud-still.png"))?.cgImage(forProposedRect: nil, context: nil, hints: nil),
   let b = opaqueBounds(still) {
    try writeSheet("cloud-still", frames: cropAndScale([still], to: b.insetBy(dx: -4, dy: -4)), delays: [1], loops: false, manifest: &manifest)
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try encoder.encode(manifest).write(to: output.appendingPathComponent("sprites.json"))
print("wrote \(manifest.count) sprites to \(output.path)")
