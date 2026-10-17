import AppKit
import ServiceManagement

final class Settings: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var popUpOnEvents: Bool { didSet { defaults.set(popUpOnEvents, forKey: "popUpOnEvents") } }
    @Published var playSound: Bool { didSet { defaults.set(playSound, forKey: "playSound") } }
    /// Clawd beside the notch while the island is closed.
    @Published var showClawd: Bool { didSet { defaults.set(showClawd, forKey: "showClawd") } }
    /// The 5-hour and weekly meters at the top of the island.
    @Published var showUsage: Bool { didSet { defaults.set(showUsage, forKey: "showUsage") } }
    /// Reorganise opens windows so every chat has one, two per desktop.
    @Published var reorganiseOpensWindows: Bool { didSet { defaults.set(reorganiseOpensWindows, forKey: "reorganiseOpensWindows") } }

    init() {
        defaults.register(defaults: ["popUpOnEvents": true, "playSound": true, "showClawd": true, "showUsage": true,
                                     "reorganiseOpensWindows": true])
        popUpOnEvents = defaults.bool(forKey: "popUpOnEvents")
        playSound = defaults.bool(forKey: "playSound")
        showClawd = defaults.bool(forKey: "showClawd")
        showUsage = defaults.bool(forKey: "showUsage")
        reorganiseOpensWindows = defaults.bool(forKey: "reorganiseOpensWindows")
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
