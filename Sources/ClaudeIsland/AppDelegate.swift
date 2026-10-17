import AppKit
import ServiceManagement

final class Settings: ObservableObject {
    /// The app's own preferences. The command-line tool runs without a bundle, so it names the domain.
    static let defaults = Bundle.main.bundleIdentifier == nil
        ? UserDefaults(suiteName: "com.arjun.claude-island") ?? .standard : .standard
    private let defaults = Settings.defaults

    /// Window layouts Reorganise can use: 2 side by side, a 2 × 2 grid, or 2 rows of 3.
    static let layouts = [2, 4, 6]

    /// The symbol for a layout, used in settings and on the Reorganise button.
    static func layoutSymbol(_ windows: Int) -> String {
        switch windows {
        case 4: return "rectangle.split.2x2"
        case 6: return "rectangle.grid.3x2"
        default: return "rectangle.split.2x1"
        }
    }

    /// Whether Reorganise opens windows for chats without one, as saved (for the CLI).
    static var savedOpensWindows: Bool { defaults.object(forKey: "reorganiseOpensWindows") as? Bool ?? true }

    /// Windows per desktop as saved, for code that runs without a Settings object (the CLI).
    static var savedWindowsPerDesktop: Int {
        let n = defaults.integer(forKey: "windowsPerDesktop")
        return layouts.contains(n) ? n : 2
    }

    @Published var popUpOnEvents: Bool { didSet { defaults.set(popUpOnEvents, forKey: "popUpOnEvents") } }
    @Published var playSound: Bool { didSet { defaults.set(playSound, forKey: "playSound") } }
    /// Clawd beside the notch while the island is closed.
    @Published var showClawd: Bool { didSet { defaults.set(showClawd, forKey: "showClawd") } }
    /// The 5-hour and weekly meters at the top of the island.
    @Published var showUsage: Bool { didSet { defaults.set(showUsage, forKey: "showUsage") } }
    /// Reorganise opens windows so every chat has one, two per desktop.
    @Published var reorganiseOpensWindows: Bool { didSet { defaults.set(reorganiseOpensWindows, forKey: "reorganiseOpensWindows") } }
    /// How many Terminal windows Reorganise puts on each desktop, tiled: 2, 4 or 6.
    @Published var windowsPerDesktop: Int { didSet { defaults.set(windowsPerDesktop, forKey: "windowsPerDesktop") } }
    /// Model, effort and context under each chat's name.
    @Published var showSessionDetails: Bool { didSet { defaults.set(showSessionDetails, forKey: "showSessionDetails") } }

    init() {
        defaults.register(defaults: ["popUpOnEvents": true, "playSound": true, "showClawd": true, "showUsage": true,
                                     "reorganiseOpensWindows": true, "showSessionDetails": true])
        popUpOnEvents = defaults.bool(forKey: "popUpOnEvents")
        playSound = defaults.bool(forKey: "playSound")
        showClawd = defaults.bool(forKey: "showClawd")
        showUsage = defaults.bool(forKey: "showUsage")
        reorganiseOpensWindows = defaults.bool(forKey: "reorganiseOpensWindows")
        windowsPerDesktop = Settings.savedWindowsPerDesktop
        showSessionDetails = defaults.bool(forKey: "showSessionDetails")
    }

    var openAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            try? newValue ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = Settings()
    let sessions = SessionStore()
    let usage = UsageStore()
    private var island: IslandController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0 != .current }) {
            NSApp.terminate(nil)
            return
        }
        let island = IslandController(sessions: sessions, usage: usage, settings: settings)
        island.setup()
        self.island = island
        sessions.start()
        usage.start()
    }
}
