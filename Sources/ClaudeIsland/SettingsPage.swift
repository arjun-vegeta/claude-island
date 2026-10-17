import SwiftUI

/// The island's settings, in place of the sessions: the same two-column sections, each setting a row
/// with a switch. Closing the island always brings back the sessions.
struct SettingsPage: View {
    @ObservedObject var controller: IslandController
    @ObservedObject var usage: UsageStore
    @ObservedObject var settings: Settings
    /// Re-read when the page opens, so a permission granted in System Settings shows up.
    @StateObject private var access = AccessCheck()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 0) {
                section("Notifications") {
                    toggle("popups", "Pop-up when a chat finishes", $settings.popUpOnEvents,
                           help: "Opens the island briefly when a chat finishes or needs you")
                    toggle("sound", "Sound", $settings.playSound,
                           help: "A chime when a chat finishes, and another when one needs you")
                }
                section("Island") {
                    toggle("clawd", "Clawd beside the notch", $settings.showClawd,
                           help: "Clawd lurks, dances and waves next to the notch while the island is closed")
                    toggle("usage", "Plan usage", $settings.showUsage,
                           help: "Your 5-hour and weekly limits at the top of the island")
                }
                section("Reorganise") {
                    VStack(spacing: IslandLayout.settingsRowGap) {
                        layoutPicker
                        HStack(spacing: 8) {
                            toggle("windows", "Open windows for every chat", $settings.reorganiseOpensWindows,
                                   help: "Chats without a window get one, filling each desktop's layout, on empty desktops if needed")
                            action("access", "Desktop switching", value: access.allowed ? "Allowed" : "Allow…",
                                   highlight: !access.allowed,
                                   help: "Reorganise presses Ctrl+→ to reach empty desktops, which needs Accessibility") {
                                access.ask()
                            }
                        }
                    }
                }
                section("General") {
                    toggle("login", "Open at login", Binding(get: { settings.openAtLogin }, set: { settings.openAtLogin = $0 }),
                           help: "Start Claude Island when you log in")
                    action("refresh", "Usage", value: usage.loading ? "Checking…" : checked(context.date),
                           highlight: false, help: "Check your plan usage now") {
                        usage.refresh()
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, IslandLayout.listBottom)
        }
        .onAppear { access.check() }
    }

    /// How many windows Reorganise tiles on each desktop: 2 side by side, 4 in a 2 × 2 grid, 6 in 2 rows of 3.
    private var layoutPicker: some View {
        row("Windows per desktop", hovered: false) {
            Text(layoutName(settings.windowsPerDesktop))
                .font(islandFont(11))
                .foregroundStyle(Color.ink3)
            Picker("Windows per desktop", selection: $settings.windowsPerDesktop) {
                ForEach(Settings.layouts, id: \.self) { n in
                    Image(systemName: layoutSymbol(n)).help(layoutName(n)).tag(n)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .environment(\.controlActiveState, .key)
        }
        .help("How Reorganise and New chat lay out Terminal windows on each desktop")
    }

    private func layoutName(_ n: Int) -> String {
        switch n {
        case 4: return "4 · 2 × 2"
        case 6: return "6 · 2 rows of 3"
        default: return "2 · side by side"
        }
    }

    private func layoutSymbol(_ n: Int) -> String {
        switch n {
        case 4: return "rectangle.split.2x2"
        case 6: return "rectangle.grid.3x2"
        default: return "rectangle.split.2x1"
        }
    }

    private func checked(_ now: Date) -> String {
        guard let at = usage.snapshot?.fetchedAt else { return "Check now" }
        let age = now.timeIntervalSince(at)
        return age < 60 ? "Checked just now" : "Checked \(shortDuration(age)) ago"
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(islandFont(10))
                .tracking(0.9)
                .foregroundStyle(Color.ink3)
                .padding(.leading, 8)
                .frame(height: IslandLayout.sectionLabel, alignment: .bottomLeading)
                .padding(.bottom, IslandLayout.sectionLabelGap)
            HStack(spacing: 8) { content() }
        }
    }

    private func toggle(_ id: String, _ title: String, _ isOn: Binding<Bool>, help: String) -> some View {
        let hovered = controller.hovered == "setting-\(id)"
        return Button { isOn.wrappedValue.toggle() } label: {
            row(title, hovered: hovered) {
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

    private func action(_ id: String, _ title: String, value: String, highlight: Bool, help: String,
                        perform: @escaping () -> Void) -> some View {
        let hovered = controller.hovered == "setting-\(id)"
        return Button(action: perform) {
            row(title, hovered: hovered) {
                Text(value)
                    .font(islandFont(11))
                    .foregroundStyle(highlight ? Color.clay : hovered ? Color.ink1 : Color.ink2)
                    .lineLimit(1)
            }
        }
        .buttonStyle(CardPress())
        .hoverTarget("setting-\(id)")
        .help(help)
    }

    private func row<Trailing: View>(_ title: String, hovered: Bool, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(islandFont(12))
                .foregroundStyle(Color.ink1)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            trailing()
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
        .frame(height: IslandLayout.settingsRow)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.ivory.opacity(hovered ? 0.08 : 0.04)))
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.1), value: hovered)
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
