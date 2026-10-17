import SwiftUI

/// Black island, warm ivory type at three strengths, and one accent (Claude's clay) used sparingly.
extension Color {
    static let ivory = Color(red: 0.98, green: 0.976, blue: 0.96)
    static let ink1 = ivory.opacity(0.92)
    static let ink2 = ivory.opacity(0.52)
    static let ink3 = ivory.opacity(0.3)
    static let hairline = ivory.opacity(0.07)
    static let clay = Color(red: 0.851, green: 0.467, blue: 0.341)
    static let sage = Color(red: 0.62, green: 0.70, blue: 0.51)
    static let alarm = Color(red: 0.93, green: 0.42, blue: 0.36)
    static let slate = Color(red: 0.08, green: 0.08, blue: 0.075)
}

/// SF Pro at regular weight: nothing in the island is bold.
func islandFont(_ size: CGFloat) -> Font {
    .system(size: size, weight: .regular)
}

/// Frames of everything clickable, in the island's coordinate space. The controller hit-tests the
/// pointer against these on every mouse move: SwiftUI's own hover lags in an app that never activates.
struct HoverFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// Makes this view hoverable under `id`: highlighted when `controller.hovered == id`, with a pointing hand.
    func hoverTarget(_ id: String) -> some View {
        background(GeometryReader { g in
            Color.clear.preference(key: HoverFrames.self, value: [id: g.frame(in: .named("island"))])
        })
    }
}

func shortDuration(_ interval: TimeInterval) -> String {
    let s = Int(max(0, interval))
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86400 {
        let h = s / 3600, m = (s % 3600) / 60
        return h < 10 && m > 0 ? "\(h)h \(m)m" : "\(h)h"
    }
    return "\(s / 86400)d"
}

/// The notch silhouette: flares into the menu bar at the top, rounded at the bottom.
struct NotchShape: Shape {
    var ear: CGFloat
    var bottom: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(ear, bottom) }
        set { ear = newValue.first; bottom = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        var p = Path()
        let b = min(bottom, (r.height - ear) / 2, (r.width - 2 * ear) / 2)
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + ear, y: r.minY + ear), control: CGPoint(x: r.minX + ear, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + ear, y: r.maxY - b))
        p.addQuadCurve(to: CGPoint(x: r.minX + ear + b, y: r.maxY), control: CGPoint(x: r.minX + ear, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - ear - b, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - ear, y: r.maxY - b), control: CGPoint(x: r.maxX - ear, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - ear, y: r.minY + ear))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - ear, y: r.minY))
        p.closeSubpath()
        return p
    }
}

struct IslandRootView: View {
    @ObservedObject var controller: IslandController
    @ObservedObject var sessions: SessionStore
    @ObservedObject var usage: UsageStore
    @ObservedObject var settings: Settings

    private var bottomRadius: CGFloat {
        switch controller.mode {
        case .collapsed: return 10
        case .expanded: return 28
        default: return 22
        }
    }

    private var modeKey: String {
        switch controller.mode {
        case .collapsed: return "collapsed"
        case .expanded: return "expanded"
        case .toast(let e): return "toast-\(e.id)"
        case .working: return "working"
        }
    }

    var body: some View {
        let size = controller.islandSize
        let open = controller.mode != .collapsed
        ZStack(alignment: .top) {
            NotchShape(ear: IslandLayout.ear, bottom: bottomRadius)
                .fill(Color.black)
                .frame(width: size.width, height: size.height)
                .shadow(color: .black.opacity(open ? 0.5 : 0), radius: 18, y: 8)
            content
                .id(modeKey)
                .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.1)),
                                        removal: .opacity.animation(.easeIn(duration: 0.08))))
                .frame(width: size.width - IslandLayout.ear * 2, height: size.height, alignment: .top)
                .clipShape(NotchShape(ear: 0, bottom: bottomRadius))
        }
        .frame(width: IslandLayout.panelSize.width, height: IslandLayout.panelSize.height, alignment: .top)
        .overlay(alignment: .top) { lurker }
        .coordinateSpace(name: "island")
        .onPreferenceChange(HoverFrames.self) { controller.hoverFrames = $0 }
        // Opening may bounce; closing must not, or the island dips above the notch's bottom edge.
        .animation(open ? .spring(response: 0.38, dampingFraction: 0.8) : .spring(response: 0.3, dampingFraction: 1), value: size)
        .environment(\.colorScheme, .dark)
    }

    /// Clawd beside the notch, straight on the menu bar, while the island is closed. The animations
    /// face right, so on the notch's left side they're mirrored to face away from it. Dancing and
    /// waving slide out from behind the notch and back.
    @ViewBuilder private var lurker: some View {
        if controller.mode == .collapsed && !controller.lurkHidden && settings.showClawd {
            let notch = controller.geometry.notchHeight
            let act = controller.lurkAct
            let size = controller.lurkerSize(act)
            let right = controller.lurkSide == .right
            let towardNotch: CGFloat = right ? -size.width : size.width
            ClawdView(name: act.sprite, height: size.height)
                .scaleEffect(x: right ? 1 : -1, y: 1)
                .frame(width: size.width, height: notch - 3, alignment: right ? .bottomLeading : .bottomTrailing)
                .offset(x: (right ? 1 : -1) * (controller.geometry.notchWidth / 2 + size.width / 2 + act.gap))
                .id(controller.lurkCycle)
                .transition(.offset(x: towardNotch).combined(with: .opacity))
        }
    }

    @ViewBuilder private var content: some View {
        switch controller.mode {
        case .collapsed:
            Color.clear
        case .expanded:
            ExpandedView(controller: controller, sessions: sessions, usage: usage, settings: settings)
        case .toast(let event):
            ToastView(event: event, notchHeight: controller.geometry.notchHeight, hovered: controller.hovered == "toast") {
                controller.focus(event.pid)
            }
            .hoverTarget("toast")
        case .working(let text, let done):
            WorkingView(text: text, done: done, notchHeight: controller.geometry.notchHeight)
        }
    }
}

// MARK: - Expanded

struct ExpandedView: View {
    @ObservedObject var controller: IslandController
    @ObservedObject var sessions: SessionStore
    @ObservedObject var usage: UsageStore
    @ObservedObject var settings: Settings

    var body: some View {
        let list = sessions.sessions
        VStack(spacing: 0) {
            header(list)

            if controller.showingSettings {
                SettingsPage(controller: controller, usage: usage, settings: settings)
                    .frame(height: controller.settingsPageHeight, alignment: .top)
                Rectangle().fill(Color.hairline).frame(height: 1).padding(.horizontal, 20)
                footer.frame(height: IslandLayout.footerHeight - 1)
            } else {
                sessionsPage(list)
            }
        }
    }

    @ViewBuilder private func sessionsPage(_ list: [ClaudeSession]) -> some View {
        if settings.showUsage {
            UsageStrip(usage: usage).frame(height: controller.usageHeight)
        }

        if let problem = sessions.terminalProblem {
            Text(problem)
                .font(islandFont(11))
                .foregroundStyle(Color.clay)
                .lineLimit(2)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: IslandLayout.bannerHeight)
        }

        if !controller.query.isEmpty {
            SearchLine(query: controller.query, matches: controller.groups.all.count)
                .frame(height: IslandLayout.searchHeight)
        }

        Rectangle().fill(Color.hairline).frame(height: 1).padding(.horizontal, 20)

        if list.isEmpty || controller.groups.isEmpty {
            VStack(spacing: 8) {
                ClawdView(name: list.isEmpty ? "cloud-still" : "cloud", height: 38)
                Text(list.isEmpty ? "No Claude Code sessions" : "No sessions match \u{201C}\(controller.query)\u{201D}")
                    .font(islandFont(12))
                    .foregroundStyle(Color.ink2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 20)
            }
            .frame(maxWidth: .infinity)
            .frame(height: controller.listHeight - 1)
        } else {
            sessionList(controller.groups).frame(height: controller.listHeight - 1)
        }

        if let note = controller.note {
            Text(note)
                .font(islandFont(11))
                .foregroundStyle(Color.ink2)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: IslandLayout.noteHeight)
        }

        Rectangle().fill(Color.hairline).frame(height: 1).padding(.horizontal, 20)
        footer.frame(height: IslandLayout.footerHeight - 1)
    }

    /// The row beside the notch: Clawd at his laptop on the left, working and done counts on the right.
    private func header(_ list: [ClaudeSession]) -> some View {
        let active = list.filter(\.isActive).count
        let finished = list.filter { $0.state == .finished }.count
        return HStack(spacing: 0) {
            ClawdView(name: controller.celebrating ? "dancing" : "laptop", height: controller.geometry.notchHeight - 6)
                .id(controller.celebrating)
            Spacer(minLength: controller.geometry.notchWidth + 16)
            HStack(spacing: 14) {
                HStack(spacing: 5) {
                    ClaudeSpark(size: 11, animated: active > 0).frame(width: 11, height: 11)
                        .id(active > 0)
                    Text("\(active) working").foregroundStyle(Color.ink2)
                }
                if finished > 0 {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark").font(.system(size: 9.5)).foregroundStyle(Color.sage)
                        Text("\(finished) done").foregroundStyle(Color.ink2)
                    }
                }
            }
            .font(islandFont(12))
        }
        .padding(.leading, 14)
        .padding(.trailing, 20)
        .frame(height: controller.geometry.notchHeight)
    }

    /// Sessions in four quiet groups: working ones as cards, then as slim rows: done (finished, not
    /// opened yet), recent (seen, finished in the last six hours) and idle (untouched for longer).
    private func sessionList(_ groups: IslandController.SessionGroups) -> some View {
        let working = groups.working, done = groups.done, recent = groups.recent, idle = groups.idle
        return TimelineView(.periodic(from: .now, by: 15)) { context in
            // AppKit keeps a scroll view pinned to the bottom as rows load in, so start at the top explicitly.
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        Color.clear.frame(height: 0).id("top")
                        if !working.isEmpty {
                            section("Working", gap: IslandLayout.cardGap) {
                                ForEach(working) { session in
                                    WorkingCard(session: session, now: context.date, hovered: isHovered(session), details: details(session)) { controller.focus(session.pid) }
                                        .hoverTarget("cell-\(session.pid)")
                                        .id(session.pid)
                                }
                            }
                        }
                        if !done.isEmpty {
                            section("Done", gap: IslandLayout.rowGap) {
                                ForEach(done) { session in
                                    SessionRow(session: session, now: context.date, hovered: isHovered(session), details: details(session),
                                               waving: controller.waving.contains(session.pid)) { controller.focus(session.pid) }
                                        .hoverTarget("cell-\(session.pid)")
                                        .id(session.pid)
                                }
                            }
                        }
                        if !recent.isEmpty {
                            section("Recent", gap: IslandLayout.rowGap) {
                                ForEach(recent) { session in
                                    SessionRow(session: session, now: context.date, hovered: isHovered(session), details: details(session)) { controller.focus(session.pid) }
                                        .hoverTarget("cell-\(session.pid)")
                                        .id(session.pid)
                                }
                            }
                        }
                        if !idle.isEmpty {
                            section("Idle", gap: IslandLayout.rowGap) {
                                ForEach(idle) { session in
                                    SessionRow(session: session, now: context.date, hovered: isHovered(session), details: details(session)) { controller.focus(session.pid) }
                                        .hoverTarget("cell-\(session.pid)")
                                        .id(session.pid)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, IslandLayout.listBottom)
                }
                .hoverTarget("list")
                .onAppear { proxy.scrollTo("top", anchor: .top) }
                .onChange(of: sessions.sessions.count) { proxy.scrollTo("top", anchor: .top) }
                .onChange(of: controller.query) { proxy.scrollTo("top", anchor: .top) }
                .onChange(of: controller.selectedPid) { _, pid in
                    guard let pid else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(pid) }
                }
            }
        }
    }

    /// The line under a chat's name: "" while it's on but not known yet, so every row keeps one height.
    private func details(_ session: ClaudeSession) -> String? {
        settings.showSessionDetails ? sessions.details[session.sessionId]?.text ?? "" : nil
    }

    /// Under the pointer, or picked with the keyboard.
    private func isHovered(_ session: ClaudeSession) -> Bool {
        controller.hovered == "cell-\(session.pid)" || controller.selectedPid == session.pid
    }

    private func section<Content: View>(_ title: String, gap: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(islandFont(10))
                .tracking(0.9)
                .foregroundStyle(Color.ink3)
                .padding(.leading, 8)
                .frame(height: IslandLayout.sectionLabel, alignment: .bottomLeading)
                .padding(.bottom, IslandLayout.sectionLabelGap)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: gap) {
                content()
            }
        }
    }

    @ViewBuilder private var footer: some View {
        let movable = controller.movableSessions.count
        if controller.showingSettings {
            HStack(spacing: 8) {
                Button("Quit Claude Island") { NSApp.terminate(nil) }
                    .buttonStyle(LinkStyle(hovered: controller.hovered == "quit"))
                    .hoverTarget("quit")
                Spacer(minLength: 4)
                Text("Esc to go back").font(islandFont(11)).foregroundStyle(Color.ink3)
                Button("Done") { controller.showingSettings = false }
                    .buttonStyle(PillStyle(filled: true, hovered: controller.hovered == "done"))
                    .hoverTarget("done")
            }
            .padding(.horizontal, 18)
        } else if controller.confirmingMove {
            HStack(spacing: 8) {
                Text("Restart \(movable) idle session\(movable == 1 ? "" : "s") inside tmux? Chats are kept; anything they run in the background stops.")
                    .font(islandFont(11))
                    .foregroundStyle(Color.ink2)
                    .lineLimit(3)
                Spacer(minLength: 4)
                Button("Cancel") { controller.confirmingMove = false }
                    .buttonStyle(PillStyle(filled: false, hovered: controller.hovered == "cancel"))
                    .hoverTarget("cancel")
                Button("Restart") { controller.moveIntoTmux() }
                    .buttonStyle(PillStyle(filled: true, hovered: controller.hovered == "restart"))
                    .hoverTarget("restart")
            }
            .padding(.horizontal, 18)
        } else {
            HStack(spacing: 8) {
                Button { controller.showingSettings = true } label: {
                    Image(systemName: "gearshape")
                        .font(islandFont(13))
                        .foregroundStyle(Color.ink1)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.ivory.opacity(controller.hovered == "settings" ? 0.13 : 0.08)))
                        .animation(.easeOut(duration: 0.1), value: controller.hovered == "settings")
                }
                .buttonStyle(CardPress())
                .hoverTarget("settings")
                .help("Settings")

                if movable > 0 {
                    Button { controller.confirmingMove = true } label: {
                        HStack(spacing: 4) {
                            Text("Move \(movable) into tmux")
                            Image(systemName: "arrow.right").font(.system(size: 10))
                        }
                    }
                    .buttonStyle(LinkStyle(hovered: controller.hovered == "move"))
                    .hoverTarget("move")
                    .help("Sessions started before the tmux setup can't be rearranged until they restart inside tmux")
                }

                Spacer(minLength: 4)

                Button(action: controller.reorganise) {
                    HStack(spacing: 6) {
                        Image(systemName: Settings.layoutSymbol(settings.windowsPerDesktop))
                        Text("Reorganise")
                    }
                }
                .buttonStyle(PillStyle(filled: false, hovered: controller.hovered == "reorganise"))
                .hoverTarget("reorganise")
                .help("Running sessions first, \(settings.windowsPerDesktop) per desktop, idle ones after")

                Button(action: controller.newChat) {
                    HStack(spacing: 6) {
                        ClawdView(name: "dancing", height: 15, playing: controller.hovered == "new-chat", skipIntro: true)
                        Text("New chat")
                    }
                }
                .buttonStyle(PillStyle(filled: true, hovered: controller.hovered == "new-chat"))
                .hoverTarget("new-chat")
                .help("Open a new Terminal window with Claude Code on this desktop")
            }
            .padding(.horizontal, 18)
        }
    }
}

/// What you've typed, with a blinking caret and how many sessions match.
struct SearchLine: View {
    let query: String
    let matches: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Color.ink3)
            HStack(spacing: 1) {
                Text(query).foregroundStyle(Color.ink1).lineLimit(1).truncationMode(.head)
                TimelineView(.periodic(from: .now, by: 0.53)) { context in
                    Rectangle().fill(Color.clay)
                        .frame(width: 1.5, height: 15)
                        .opacity(Int(context.date.timeIntervalSinceReferenceDate / 0.53) % 2 == 0 ? 1 : 0)
                }
            }
            .font(islandFont(13))
            Spacer(minLength: 8)
            Text(matches == 1 ? "1 match" : "\(matches) matches").foregroundStyle(Color.ink3)
            Text("esc").foregroundStyle(Color.ink3)
                .padding(.horizontal, 5)
                .frame(height: 16)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.ivory.opacity(0.06)))
        }
        .font(islandFont(11))
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.ivory.opacity(0.06)))
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
        .frame(maxHeight: .infinity, alignment: .bottom)
    }
}

// MARK: - Buttons

/// Ivory pill (filled) or a faint one, brightening on hover and dipping when pressed.
struct PillStyle: ButtonStyle {
    let filled: Bool
    let hovered: Bool

    func makeBody(configuration: Configuration) -> some View {
        let fill = filled
            ? Color.ivory.opacity(configuration.isPressed ? 0.8 : hovered ? 0.95 : 0.88)
            : Color.ivory.opacity(configuration.isPressed ? 0.16 : hovered ? 0.13 : 0.08)
        return configuration.label
            .font(islandFont(12))
            .foregroundStyle(filled ? Color.slate : Color.ink1)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Capsule().fill(fill))
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.easeOut(duration: 0.1), value: hovered)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
            .fixedSize()
    }
}

/// A clay text link, for the one-off "Move into tmux" step.
struct LinkStyle: ButtonStyle {
    let hovered: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(islandFont(12))
            .foregroundStyle(Color.clay.opacity(configuration.isPressed ? 0.6 : hovered ? 1 : 0.85))
            .padding(.horizontal, 6)
            .frame(height: 28)
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.1), value: hovered)
            .fixedSize()
    }
}

/// Rows and the pop-up: a soft ivory wash on hover and a small press-down.
struct HighlightStyle: ButtonStyle {
    var cornerRadius: CGFloat = 10
    let hovered: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.ivory.opacity(configuration.isPressed ? 0.1 : hovered ? 0.06 : 0)))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.1), value: hovered)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Usage

struct UsageStrip: View {
    @ObservedObject var usage: UsageStore

    var body: some View {
        Group {
            if let snapshot = usage.snapshot {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(alignment: .top, spacing: 22) {
                        ForEach(snapshot.windows.prefix(3)) { UsageMeter(window: $0) }
                        if snapshot.windows.count < 3, let used = snapshot.extraUsed, let limit = snapshot.extraLimit, limit > 0 {
                            UsageMeter(window: UsageWindow(id: "extra", label: "Extra usage", percent: used / limit * 100, resetsAt: nil),
                                       caption: "\(money(used, snapshot.currency)) of \(money(limit, snapshot.currency))")
                        }
                    }
                    .opacity(usage.isStale ? 0.6 : 1)
                    if usage.isStale {
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            HStack(spacing: 6) {
                                Image(systemName: usage.offline ? "wifi.slash" : "exclamationmark.triangle")
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(Color.clay)
                                Text(staleText(snapshot, now: context.date))
                                    .foregroundStyle(Color.ink3)
                                    .lineLimit(1)
                            }
                            .font(islandFont(10.5))
                        }
                    }
                }
            } else if usage.offline {
                HStack(spacing: 6) {
                    Image(systemName: "wifi.slash").foregroundStyle(Color.clay)
                    Text("Usage unavailable offline · connect to the internet")
                }
                .font(islandFont(11))
                .foregroundStyle(Color.ink2)
            } else if usage.loading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Asking claude for usage…")
                }
                .font(islandFont(11))
                .foregroundStyle(Color.ink2)
            } else {
                Text(usage.error.map { "Usage unavailable: \($0)" } ?? "Usage unavailable")
                    .font(islandFont(11))
                    .foregroundStyle(Color.ink2)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func staleText(_ snapshot: UsageSnapshot, now: Date) -> String {
        let age = now.timeIntervalSince(snapshot.fetchedAt)
        let checked = age < 60 ? "Last checked just now" : "Last checked \(shortDuration(age)) ago"
        return checked + (usage.offline ? " · connect to the internet to update" : " · couldn't update")
    }

    private func money(_ value: Double, _ currency: String) -> String {
        value.formatted(.currency(code: currency).precision(.fractionLength(value >= 100 ? 0 : 2)))
    }
}

struct UsageMeter: View {
    let window: UsageWindow
    var caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.label).foregroundStyle(Color.ink3)
                Spacer()
                Text("\(Int(window.percent.rounded()))%").foregroundStyle(Color.ink1).monospacedDigit()
            }
            .font(islandFont(11))
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.ivory.opacity(0.08))
                    Capsule().fill(window.percent >= 85 ? Color.alarm : Color.clay)
                        .frame(width: max(3, g.size.width * min(window.percent, 100) / 100))
                }
            }
            .frame(height: 3)
            Text(caption ?? resetText)
                .font(islandFont(10))
                .foregroundStyle(Color.ink3)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private var resetText: String {
        guard let date = window.resetsAt else { return " " }
        let left = date.timeIntervalSinceNow
        if left <= 0 { return "resetting" }
        if left < 86400 { return "resets in \(shortDuration(left))" }
        return "resets " + date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}

// MARK: - Sessions

/// A session Claude is working on (or that needs you): a soft card with the live spinner.
struct WorkingCard: View {
    let session: ClaudeSession
    let now: Date
    let hovered: Bool
    /// Model, effort and context; nil when that setting is off.
    let details: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if session.state == .needsYou {
                    Image(systemName: "hand.raised.fill").font(.system(size: 11)).foregroundStyle(Color.clay).frame(width: 16)
                } else {
                    ClaudeSpark(size: 16).frame(width: 16, height: 16)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.name)
                        .font(islandFont(13))
                        .foregroundStyle(Color.ink1)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(detail)
                        .font(islandFont(11))
                        .foregroundStyle(session.state == .needsYou ? Color.clay : Color.ink2)
                        .lineLimit(1)
                    if let details {
                        DetailsLine(text: details)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: IslandLayout.cardHeight + (details == nil ? 0 : IslandLayout.detailsLine))
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.ivory.opacity(hovered ? 0.09 : 0.05)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(session.state == .needsYou ? Color.clay.opacity(0.45) : Color.ivory.opacity(0.06), lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(CardPress())
        .animation(.easeOut(duration: 0.1), value: hovered)
    }

    private var detail: String {
        switch session.state {
        case .needsYou: return "Needs your \(session.waitingFor.map { $0.replacingOccurrences(of: " prompt", with: "") } ?? "input")"
        default:
            let since = "Working · \(shortDuration(now.timeIntervalSince(session.since)))"
            return session.onScreen || !session.inTmux ? since : since + " · no window"
        }
    }
}

/// "Opus 5.5 · high · 38% of 1M" under a chat's name.
struct DetailsLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(islandFont(10.5))
            .foregroundStyle(Color.ink3)
            .monospacedDigit()
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

struct CardPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// A recent or idle session: one slim line, name on the left and time on the right. Unseen finishes
/// carry a check; recent ones read a little brighter than idle ones.
struct SessionRow: View {
    let session: ClaudeSession
    let now: Date
    let hovered: Bool
    /// Model, effort and context; nil when that setting is off.
    let details: String?
    /// Just finished (its pop-up fired): Clawd waves where the check would be.
    var waving = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Group {
                    if waving {
                        ClawdView(name: "waving", height: 15)
                    } else if session.state == .finished {
                        Image(systemName: "checkmark").font(.system(size: 9.5)).foregroundStyle(Color.sage)
                    } else {
                        Circle().fill(Color.ivory.opacity(session.recent ? 0.5 : 0.18)).frame(width: 4, height: 4)
                    }
                }
                .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(session.name)
                            .font(islandFont(12.5))
                            .foregroundStyle(session.recent || session.state == .finished ? Color.ink1 : Color.ivory.opacity(0.72))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 6)
                        Text(age)
                            .font(islandFont(11))
                            .foregroundStyle(Color.ink3)
                            .monospacedDigit()
                    }
                    if let details {
                        DetailsLine(text: details)
                    }
                }
            }
            .padding(.horizontal, 8)
            .frame(height: IslandLayout.rowHeight + (details == nil ? 0 : IslandLayout.detailsLine))
            .contentShape(Rectangle())
        }
        .buttonStyle(HighlightStyle(hovered: hovered))
    }

    private var age: String {
        let elapsed = now.timeIntervalSince(session.since)
        let time = elapsed < 60 ? "now" : shortDuration(elapsed)
        return session.inTmux && !session.onScreen ? "\(time) · hidden" : time
    }
}

// MARK: - Pop-ups

/// Pop-up layout: Clawd stands in the corner beside the notch, the text sits below the notch line.
struct PopupLayout: View {
    let clawd: String
    let title: String
    let detail: String
    var detailColor: Color = .ink2
    let notchHeight: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            ClawdView(name: clawd, height: 46)
                .frame(width: 58, height: 46, alignment: .bottom)
                .padding(.leading, 12)
                .padding(.top, 16)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(islandFont(13))
                    .foregroundStyle(Color.ink1)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(detail)
                    .font(islandFont(11))
                    .foregroundStyle(detailColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.leading, 80)
            .padding(.trailing, 16)
            .padding(.top, notchHeight + 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// "Finished" and "needs you" pop-ups: Clawd jumps for joy, or waves to get your attention.
struct ToastView: View {
    let event: SessionEvent
    let notchHeight: CGFloat
    let hovered: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            switch event.kind {
            case .finished(let ran):
                PopupLayout(clawd: "jumping", title: event.name, detail: "Finished · took \(shortDuration(ran))", notchHeight: notchHeight)
            case .needsInput(let what):
                PopupLayout(clawd: "waving", title: event.name, detail: "Needs you · \(what)", detailColor: .clay, notchHeight: notchHeight)
            }
        }
        // Stays black on hover; only the press gives a little.
        .buttonStyle(CardPress())
    }
}

/// Progress while sessions move into tmux: Clawd walks them over, then dances when it's done.
struct WorkingView: View {
    let text: String
    let done: Bool
    let notchHeight: CGFloat

    var body: some View {
        PopupLayout(clawd: done ? "dancing" : "crab", title: done ? "All set" : "Moving into tmux", detail: text, notchHeight: notchHeight)
            .id(done)
    }
}
