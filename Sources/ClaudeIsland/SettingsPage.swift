import SwiftUI

/// The island's settings, in place of the sessions: one column of grouped rows, like System Settings,
/// so every label fits. Closing the island always brings back the sessions.
struct SettingsPage: View {
    @ObservedObject var controller: IslandController
    @ObservedObject var usage: UsageStore
    @ObservedObject var settings: Settings
    /// Re-read when the page opens, so a permission granted in System Settings shows up.
    @StateObject private var access = AccessCheck()
    @StateObject private var hook = HookCheck()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 0) {
                group("Notifications") {
                    toggle("popups", "Pop-up when a chat finishes or needs you", $settings.popUpOnEvents, first: true,
                           help: "Opens the island briefly with the chat's name")
                    toggle("sound", "Sound", $settings.playSound,
                           help: "A chime when a chat finishes, and another when one needs you")
                }
                group("Island") {
                    toggle("clawd", "Clawd beside the notch", $settings.showClawd, first: true,
                           help: "Clawd lurks, dances and waves next to the notch while the island is closed")
                    toggle("usage", "Plan usage", $settings.showUsage,
                           help: "Your 5-hour and weekly limits at the top of the island")
                    toggle("details", "Model, effort and context under each chat", $settings.showSessionDetails,
                           help: "From each chat's latest reply, for example “Opus 5.5 · high · 38% of 1M”")
                }
                group("Reorganise") {
                    layoutPicker
                    toggle("windows", "Open windows for chats without one", $settings.reorganiseOpensWindows,
                           help: "Fills each desktop's layout, using empty desktops if needed")
                    action("access", "Desktop switching", value: access.allowed ? "Allowed" : "Allow…",
                           highlight: !access.allowed,
                           help: "Reorganise presses Ctrl+→ to reach empty desktops, which needs Accessibility") {
                        access.ask()
                    }
                }
                group("General") {
                    action("terminal", "Terminal setup", value: hook.hooked ? "Done" : "Set up", highlight: !hook.hooked, first: true,
                           help: hook.hooked ? "Typing claude in Terminal starts it inside Claude Island"
                                             : "Adds one line to ~/.zshrc so typing claude in Terminal starts it inside Claude Island") {
                        hook.setUp()
                    }
                    toggle("login", "Open at login", Binding(get: { settings.openAtLogin }, set: { settings.openAtLogin = $0 }),
                           help: "Start Claude Island when you log in")
                    action("refresh", "Check plan usage", value: usage.loading ? "Checking…" : checked(context.date),
                           highlight: false, help: "Check your plan usage now") {
                        usage.refresh()
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, IslandLayout.listBottom)
        }
        .onAppear { access.check(); hook.check() }
    }

    /// How many windows Reorganise tiles on each desktop: 2 side by side, 4 in a 2 × 2 grid, 6 in 2 rows of 3.
    private var layoutPicker: some View {
        row("Windows per desktop", hovered: false, first: true) {
            Text(layoutName(settings.windowsPerDesktop))
                .font(islandFont(11))
                .foregroundStyle(Color.ink3)
                .lineLimit(1)
            LayoutSegments(selection: $settings.windowsPerDesktop,
                           options: Settings.layouts.map { (value: $0, symbol: Settings.layoutSymbol($0), name: layoutName($0)) })
                .fixedSize()
        }
        .help("How Reorganise and New chat lay out Terminal windows on each desktop")
    }

    private func layoutName(_ n: Int) -> String {
        switch n {
        case 4: return "2 × 2"
        case 6: return "2 rows of 3"
        default: return "Side by side"
        }
    }

    private func checked(_ now: Date) -> String {
        guard let at = usage.snapshot?.fetchedAt else { return "Check now" }
        let age = now.timeIntervalSince(at)
        return age < 60 ? "Checked just now" : "Checked \(shortDuration(age)) ago"
    }

    /// A titled group: its rows share one rounded panel, with hairlines between them.
    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(islandFont(10))
                .tracking(0.9)
                .foregroundStyle(Color.ink3)
                .padding(.leading, 12)
                .frame(height: IslandLayout.sectionLabel, alignment: .bottomLeading)
                .padding(.bottom, IslandLayout.sectionLabelGap)
            VStack(spacing: 0) { content() }
                .background(Color.ivory.opacity(0.045))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func toggle(_ id: String, _ title: String, _ isOn: Binding<Bool>, first: Bool = false, help: String) -> some View {
        let hovered = controller.hovered == "setting-\(id)"
        return Button { isOn.wrappedValue.toggle() } label: {
            row(title, hovered: hovered, first: first) {
                // macOS's own switch, so it looks and moves like System Settings (Liquid Glass on macOS 26+).
                Toggle(title, isOn: isOn)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    // The island never makes the app active, and AppKit draws switches in inactive
                    // windows grey; draw them as in a key window, in Claude's orange,
                    // 15% smaller than standard.
                    .environment(\.controlActiveState, .key)
                    // The glass switch washes its tint out, so it gets a brighter clay than the rest of the island.
                    .tint(Color(red: 0.92, green: 0.47, blue: 0.32))
                    .scaleEffect(0.85)
            }
        }
        .buttonStyle(CardPress())
        .hoverTarget("setting-\(id)")
        .help(help)
    }

    private func action(_ id: String, _ title: String, value: String, highlight: Bool, first: Bool = false, help: String,
                        perform: @escaping () -> Void) -> some View {
        let hovered = controller.hovered == "setting-\(id)"
        return Button(action: perform) {
            row(title, hovered: hovered, first: first) {
                Text(value)
                    .font(islandFont(11.5))
                    .foregroundStyle(highlight ? Color.clay : hovered ? Color.ink1 : Color.ink2)
                    .lineLimit(1)
            }
        }
        .buttonStyle(CardPress())
        .hoverTarget("setting-\(id)")
        .help(help)
    }

    /// One setting: its name on the left, its control on the right, a hairline above unless it's first.
    private func row<Trailing: View>(_ title: String, hovered: Bool, first: Bool, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(islandFont(12.5))
                .foregroundStyle(Color.ink1)
                .lineLimit(1)
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .frame(maxWidth: .infinity)
        .frame(height: IslandLayout.settingsRow)
        .background(Color.ivory.opacity(hovered ? 0.05 : 0))
        .overlay(alignment: .top) {
            if !first { Rectangle().fill(Color.hairline).frame(height: 1).padding(.leading, 14) }
        }
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.1), value: hovered)
    }
}

/// AppKit's segmented control, for the one thing SwiftUI's segmented picker can't do on macOS:
/// show the selected segment in Claude's orange instead of the system accent colour.
private struct LayoutSegments: NSViewRepresentable {
    @Binding var selection: Int
    let options: [(value: Int, symbol: String, name: String)]

    func makeNSView(context: Context) -> NSSegmentedControl {
        let images = options.map { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: $0.name) ?? NSImage() }
        let control = NSSegmentedControl(images: images, trackingMode: .selectOne,
                                         target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        control.controlSize = .small
        // The same brighter clay as the switches.
        control.selectedSegmentBezelColor = NSColor(red: 0.92, green: 0.47, blue: 0.32, alpha: 1)
        for (i, option) in options.enumerated() { control.setToolTip(option.name, forSegment: i) }
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        control.selectedSegment = options.firstIndex { $0.value == selection } ?? 0
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: LayoutSegments
        init(_ parent: LayoutSegments) { self.parent = parent }

        @objc func changed(_ control: NSSegmentedControl) {
            guard parent.options.indices.contains(control.selectedSegment) else { return }
            parent.selection = parent.options[control.selectedSegment].value
        }
    }
}

/// Whether ~/.zshrc runs `claude` through Claude Island, for the "Terminal setup" row.
private final class HookCheck: ObservableObject {
    @Published private(set) var hooked = ShellSupport.isHooked

    func check() { hooked = ShellSupport.isHooked }

    func setUp() {
        try? ShellSupport.hook()
        check()
    }
}

/// Whether Claude Island may press keys (Accessibility), for the "Desktop switching" row.
private final class AccessCheck: ObservableObject {
    @Published private(set) var allowed = Desktops.canPressKeys(ask: false)

    func check() { allowed = Desktops.canPressKeys(ask: false) }

    /// Shows macOS's prompt, which leads to System Settings; checks again when you come back.
    func ask() {
        guard !Desktops.canPressKeys(ask: true) else { allowed = true; return }
        for delay in [2.0, 5, 10, 20] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.check() }
        }
    }
}
