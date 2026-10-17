import AppKit
import SwiftUI

/// Claude's starburst mark, drawn natively from its SVG path (Simple Icons "claude", 24×24 viewBox).
/// It's one outline with twelve rays; a ray is stretched by pushing the outline out near its angle.
enum ClaudeMark {
    private static let svgPath = "m4.7144 15.9555 4.7174-2.6471.079-.2307-.079-.1275h-.2307l-.7893-.0486-2.6956-.0729-2.3375-.0971-2.2646-.1214-.5707-.1215-.5343-.7042.0546-.3522.4797-.3218.686.0608 1.5179.1032 2.2767.1578 1.6514.0972 2.4468.255h.3886l.0546-.1579-.1336-.0971-.1032-.0972L6.973 9.8356l-2.55-1.6879-1.3356-.9714-.7225-.4918-.3643-.4614-.1578-1.0078.6557-.7225.8803.0607.2246.0607.8925.686 1.9064 1.4754 2.4893 1.8336.3643.3035.1457-.1032.0182-.0728-.164-.2733-1.3539-2.4467-1.445-2.4893-.6435-1.032-.17-.6194c-.0607-.255-.1032-.4674-.1032-.7285L6.287.1335 6.6997 0l.9957.1336.419.3642.6192 1.4147 1.0018 2.2282 1.5543 3.0296.4553.8985.2429.8318.091.255h.1579v-.1457l.1275-1.706.2368-2.0947.2307-2.6957.0789-.7589.3764-.9107.7468-.4918.5828.2793.4797.686-.0668.4433-.2853 1.8517-.5586 2.9021-.3643 1.9429h.2125l.2429-.2429.9835-1.3053 1.6514-2.0643.7286-.8196.85-.9046.5464-.4311h1.0321l.759 1.1293-.34 1.1657-1.0625 1.3478-.8804 1.1414-1.2628 1.7-.7893 1.36.0729.1093.1882-.0183 2.8535-.607 1.5421-.2794 1.8396-.3157.8318.3886.091.3946-.3278.8075-1.967.4857-2.3072.4614-3.4364.8136-.0425.0304.0486.0607 1.5482.1457.6618.0364h1.621l3.0175.2247.7892.522.4736.6376-.079.4857-1.2142.6193-1.6393-.3886-3.825-.9107-1.3113-.3279h-.1822v.1093l1.0929 1.0686 2.0035 1.8092 2.5075 2.3314.1275.5768-.3218.4554-.34-.0486-2.2039-1.6575-.85-.7468-1.9246-1.621h-.1275v.17l.4432.6496 2.3436 3.5214.1214 1.0807-.17.3521-.6071.2125-.6679-.1214-1.3721-1.9246L14.38 17.959l-1.1414-1.9428-.1397.079-.674 7.2552-.3156.3703-.7286.2793-.6071-.4614-.3218-.7468.3218-1.4753.3886-1.9246.3157-1.53.2853-1.9004.17-.6314-.0121-.0425-.1397.0182-1.4328 1.9672-2.1796 2.9446-1.7243 1.8456-.4128.164-.7164-.3704.0667-.6618.4008-.5889 2.386-3.0357 1.4389-1.882.929-1.0868-.0062-.1579h-.0546l-6.3385 4.1164-1.1293.1457-.4857-.4554.0608-.7467.2307-.2429 1.9064-1.3114Z"

    private enum Element {
        case move(CGPoint)
        case line(CGPoint)
        case curve(CGPoint, CGPoint, CGPoint)
        case close
    }

    private static let center = CGPoint(x: 12, y: 12)
    /// The solid middle; only the outline beyond it stretches.
    private static let hub: CGFloat = 3
    /// How far a ray's stretch spreads to either side of it.
    private static let spread: CGFloat = 9 * .pi / 180

    private static let elements: [Element] = parse(svgPath)

    /// Angles of the twelve ray tips: the outline's points that stick out furthest.
    static let rayAngles: [CGFloat] = {
        var points: [CGPoint] = []
        for e in elements {
            switch e {
            case .move(let p), .line(let p), .curve(_, _, let p): points.append(p)
            case .close: break
            }
        }
        let radius = points.map { hypot($0.x - center.x, $0.y - center.y) }
        return radius.indices.dropFirst().dropLast().compactMap { k in
            radius[k] > 7 && radius[k] > radius[k - 1] && radius[k] >= radius[k + 1]
                ? atan2(points[k].y - center.y, points[k].x - center.x) : nil
        }
    }()

    /// The mark at rest, in its 24×24 SVG coordinates (y down).
    static let path: CGPath = deformed([])

    /// The mark with each ray stretched by `stretch[i]` (0 = at rest, 0.3 = 30% longer).
    static func deformed(_ stretch: [CGFloat]) -> CGPath {
        func move(_ p: CGPoint) -> CGPoint {
            let dx = p.x - center.x, dy = p.y - center.y
            let r = hypot(dx, dy)
            guard r > hub, !stretch.isEmpty else { return p }
            let angle = atan2(dy, dx)
            var grow: CGFloat = 0
            for (i, ray) in rayAngles.enumerated() where i < stretch.count && stretch[i] > 0 {
                var delta = angle - ray
                if delta > .pi { delta -= 2 * .pi } else if delta < -.pi { delta += 2 * .pi }
                grow += stretch[i] * exp(-(delta * delta) / (2 * spread * spread))
            }
            let scale = (hub + (r - hub) * (1 + grow)) / r
            return CGPoint(x: center.x + dx * scale, y: center.y + dy * scale)
        }
        let path = CGMutablePath()
        for e in elements {
            switch e {
            case .move(let p): path.move(to: move(p))
            case .line(let p): path.addLine(to: move(p))
            case .curve(let c1, let c2, let p): path.addCurve(to: move(p), control1: move(c1), control2: move(c2))
            case .close: path.closeSubpath()
            }
        }
        return path
    }

    /// Reads the commands the mark uses (M/m, L/l, H/h, V/v, C/c, Z/z) into absolute coordinates.
    private static func parse(_ d: String) -> [Element] {
        let tokens = d.matches(of: #/[A-Za-z]|-?(?:\d+\.?\d*|\.\d+)/#).map { String(d[$0.range]) }
        var out: [Element] = []
        var i = 0
        var command: Character = "M"
        var current = CGPoint.zero
        var start = CGPoint.zero
        func number() -> CGFloat {
            defer { i += 1 }
            return CGFloat(Double(tokens[i]) ?? 0)
        }
        while i < tokens.count {
            if let c = tokens[i].first, c.isLetter {
                command = c
                i += 1
                if c == "Z" || c == "z" {
                    out.append(.close)
                    current = start
                    continue
                }
            }
            let relative = command.isLowercase
            let base = relative ? current : .zero
            switch command.uppercased() {
            case "M":
                current = CGPoint(x: base.x + number(), y: base.y + number())
                start = current
                out.append(.move(current))
                command = relative ? "l" : "L"   // further pairs after M are line-tos
            case "L":
                current = CGPoint(x: base.x + number(), y: base.y + number())
                out.append(.line(current))
            case "H":
                current = CGPoint(x: (relative ? current.x : 0) + number(), y: current.y)
                out.append(.line(current))
            case "V":
                current = CGPoint(x: current.x, y: (relative ? current.y : 0) + number())
                out.append(.line(current))
            case "C":
                let c1 = CGPoint(x: base.x + number(), y: base.y + number())
                let c2 = CGPoint(x: base.x + number(), y: base.y + number())
                current = CGPoint(x: base.x + number(), y: base.y + number())
                out.append(.curve(c1, c2, current))
            default:
                i += 1
            }
        }
        return out
    }
}

/// Claude's mark in clay. Animated, it doesn't turn: a gentle wave of rays stretches out and settles
/// back. The motion runs in Core Animation, so it costs the app nothing per frame.
struct ClaudeSpark: NSViewRepresentable {
    var size: CGFloat
    var animated = true

    func makeNSView(context: Context) -> NSView { ClaudeSparkView(animated: animated) }
    func updateNSView(_ view: NSView, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        CGSize(width: size, height: size)
    }
}

private final class ClaudeSparkView: NSView {
    private let shape = CAShapeLayer()
    private let animated: Bool
    private var laidOutSize: CGSize = .zero

    init(animated: Bool) {
        self.animated = animated
        super.init(frame: .zero)
        wantsLayer = true
        shape.fillColor = NSColor(red: 0.851, green: 0.467, blue: 0.341, alpha: 1).cgColor
        layer?.addSublayer(shape)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        guard bounds.size != laidOutSize, bounds.width > 0 else { return }
        laidOutSize = bounds.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.frame = bounds
        // Scale the 24×24 SVG (y down) into the layer (y up).
        let s = min(bounds.width, bounds.height) / 24
        var fit = CGAffineTransform(a: s, b: 0, c: 0, d: -s, tx: (bounds.width - 24 * s) / 2, ty: (bounds.height + 24 * s) / 2)
        shape.path = ClaudeMark.path.copy(using: &fit)
        CATransaction.commit()
        if animated { startStretching(&fit) }
    }

    /// A wave that swells through the rays in turn, five places apart each step, so it jumps across
    /// the mark instead of creeping round it, and every ray still gets its turn. Each swell overlaps
    /// the next, so about three rays move at once. Every view starts at a different point in the cycle.
    private func startStretching(_ fit: inout CGAffineTransform) {
        let rays = ClaudeMark.rayAngles.count
        let gap = 0.28                    // between one ray starting and the next
        let swell = 0.9                   // how long one ray takes to stretch and settle
        let peak: CGFloat = 0.28
        let cycle = gap * Double(rays)
        let steps = 48
        var turn = Array(repeating: 0, count: rays)
        for k in 0..<rays { turn[(k * 5) % rays] = k }
        let stretch: [[CGFloat]] = (0...steps).map { step in
            let t = cycle * Double(step) / Double(steps)
            return (0..<rays).map { ray in
                let phase = (t - Double(turn[ray]) * gap).truncatingRemainder(dividingBy: cycle)
                let p = (phase < 0 ? phase + cycle : phase) / swell
                return p < 1 ? peak * CGFloat(pow(sin(.pi * p), 2)) : 0
            }
        }
        let frames = stretch.map { ClaudeMark.deformed($0).copy(using: &fit)! }
        let animation = CAKeyframeAnimation(keyPath: "path")
        animation.values = frames
        animation.keyTimes = (0...steps).map { NSNumber(value: Double($0) / Double(steps)) }
        animation.duration = cycle
        animation.timeOffset = Double.random(in: 0..<cycle)
        animation.repeatCount = .infinity
        shape.removeAnimation(forKey: "stretch")
        shape.add(animation, forKey: "stretch")
    }
}
