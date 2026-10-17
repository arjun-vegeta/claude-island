import AppKit
import SwiftUI

/// One Clawd animation: frames cut from a sprite sheet made by scripts/make-sprites.swift.
final class Sprite {
    let frames: [CGImage]
    let delays: [Double]
    let loops: Bool
    let aspect: CGFloat
    let duration: Double

    init(frames: [CGImage], delays: [Double], loops: Bool) {
        self.frames = frames
        self.delays = delays
        self.loops = loops
        aspect = CGFloat(frames[0].width) / CGFloat(frames[0].height)
        duration = max(delays.reduce(0, +), 0.01)
    }

    /// How long the animation opens on frames identical to the first (Clawd standing before he moves).
    lazy var stillIntro: Double = {
        guard let first = frames[0].dataProvider?.data as Data? else { return 0 }
        var t = 0.0
        for (i, frame) in frames.enumerated().dropFirst() {
            guard frame.dataProvider?.data as Data? == first else { break }
            t += delays[i - 1]
        }
        return t
    }()

    func frame(at elapsed: Double) -> CGImage {
        var t = loops ? elapsed.truncatingRemainder(dividingBy: duration) : min(elapsed, duration - 0.001)
        for (i, delay) in delays.enumerated() {
            if t < delay { return frames[i] }
            t -= delay
        }
        return frames[frames.count - 1]
    }
}

enum Clawd {
    private struct Entry: Decodable {
        let frames: Int
        let width: Int
        let height: Int
        let delays: [Double]
        let loops: Bool
    }

    /// The app bundle's Resources/clawd, or the source tree's when running the bare binary.
    private static let directory: URL? = {
        let candidates = [Bundle.main.resourceURL?.appendingPathComponent("clawd"),
                          FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("claude-island/Resources/clawd")]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("sprites.json").path) }
    }()

    private static let manifest: [String: Entry] = {
        guard let directory, let data = try? Data(contentsOf: directory.appendingPathComponent("sprites.json")) else { return [:] }
        return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }()

    private static var cache: [String: Sprite] = [:]

    /// Call on the main thread.
    static func sprite(_ name: String) -> Sprite? {
        if let hit = cache[name] { return hit }
        guard let directory, let entry = manifest[name],
              let sheet = NSImage(contentsOf: directory.appendingPathComponent("\(name).png"))?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }
        let frames = (0..<entry.frames).compactMap { i in
            sheet.cropping(to: CGRect(x: i * entry.width, y: 0, width: entry.width, height: entry.height))
        }
        guard !frames.isEmpty else { return nil }
        let sprite = Sprite(frames: frames, delays: entry.delays, loops: entry.loops)
        cache[name] = sprite
        return sprite
    }
}

/// Plays a Clawd animation at the given height, from its first frame when it appears. The frames run
/// as a Core Animation keyframe animation, so the render server plays them and the app stays idle.
struct ClawdView: View {
    let name: String
    let height: CGFloat
    /// When false, Clawd holds still on the first frame.
    var playing = true
    /// Skip the still frames some animations open with, so the motion starts at once (e.g. on hover).
    var skipIntro = false

    var body: some View {
        if let sprite = Clawd.sprite(name) {
            SpriteLayer(sprite: sprite, playing: playing, skipIntro: skipIntro)
                .frame(width: height * sprite.aspect, height: height)
                .id(playing)
        }
    }
}

private struct SpriteLayer: NSViewRepresentable {
    let sprite: Sprite
    let playing: Bool
    var skipIntro = false

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let layer = view.layer!
        layer.contentsGravity = .resizeAspect
        layer.minificationFilter = .trilinear
        layer.contents = sprite.frames[0]
        guard playing else { return view }

        let duration = sprite.delays.reduce(0, +)
        var keyTimes: [NSNumber] = []
        var t = 0.0
        for delay in sprite.delays {
            keyTimes.append(NSNumber(value: t / duration))
            t += delay
        }
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = sprite.frames
        animation.keyTimes = keyTimes
        animation.calculationMode = .discrete
        animation.duration = duration
        animation.repeatCount = sprite.loops ? .infinity : 1
        if skipIntro { animation.timeOffset = sprite.stillIntro }
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: "frames")
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

/// Clawd's pixel logo (assets/clawd/clawd.svg, 66×52): a clay body with two dark eyes.
struct ClawdLogo: View {
    var height: CGFloat

    var body: some View {
        Canvas { context, size in
            let s = size.height / 52
            var body = Path()
            let outline: [(CGFloat, CGFloat)] = [(60, 13), (66, 13), (66, 26), (60, 26), (60, 52), (54, 52), (54, 39), (48, 39), (48, 52),
                                                 (42, 52), (42, 39), (24, 39), (24, 52), (18, 52), (18, 39), (12, 39), (12, 52),
                                                 (6, 52), (6, 26), (0, 26), (0, 13), (6, 13), (6, 0), (60, 0)]
            body.move(to: CGPoint(x: outline[0].0 * s, y: outline[0].1 * s))
            for (x, y) in outline.dropFirst() { body.addLine(to: CGPoint(x: x * s, y: y * s)) }
            body.closeSubpath()
            context.fill(body, with: .color(Color(red: 0.851, green: 0.467, blue: 0.341)))
            for x in [12.0, 48.0] {
                context.fill(Path(CGRect(x: x * s, y: 13 * s, width: 6 * s, height: 6 * s)), with: .color(Color(red: 0.08, green: 0.08, blue: 0.075)))
            }
        }
        .frame(width: height * 66 / 52, height: height)
    }
}
