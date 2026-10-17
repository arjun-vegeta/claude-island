import AppKit
import ServiceManagement

final class Settings: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var popUpOnEvents: Bool { didSet { defaults.set(popUpOnEvents, forKey: "popUpOnEvents") } }
    @Published var playSound: Bool { didSet { defaults.set(playSound, forKey: "playSound") } }

    init() {
        defaults.register(defaults: ["popUpOnEvents": true, "playSound": true])
        popUpOnEvents = defaults.bool(forKey: "popUpOnEvents")
        playSound = defaults.bool(forKey: "playSound")
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
