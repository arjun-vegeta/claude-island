import AppKit

/// `ClaudeIsland --cli <command>` for checking things from a terminal.
///   list               sessions with status, tmux session, window and desktop
///   usage              plan usage from the claude binary
///   plan               what Reorganise would do, without doing it
///   reorganise         do it
///   move-to-tmux <pid> restart one idle session inside tmux, in its own window
///   new-chat           open a new Terminal window with Claude Code on this desktop
///   demo [dance|wave|race]  make the running app show a "finished" pop-up, or bring Clawd out
enum CLI {
    static func run(_ args: [String]) {
        signal(SIGPIPE, SIG_IGN)
        switch args.first ?? "" {
        case "list": list(loadedStore())
        case "usage": usage()
        case "plan": reorganise(execute: false)
        case "desktops": desktops()
        case "reorganise", "reorganize": reorganise(execute: true)
        case "move-to-tmux" where args.count == 2: moveToTmux(pid: Int32(args[1]) ?? 0)
        case "demo":
            DistributedNotificationCenter.default().postNotificationName(IslandController.demoNotification, object: args.dropFirst().first,
                                                                         userInfo: nil, deliverImmediately: true)
        case "new-chat":
            do { try Reorganizer.openNewChat(screens: ScreenInfo.all(), capacity: Settings.savedWindowsPerDesktop) } catch { print("error: \(error.localizedDescription)") }
        default: print("commands: list | usage | plan | reorganise | move-to-tmux <pid> | new-chat | demo [dance|wave|race]")
        }
    }

    /// A session store with Terminal and tmux already read.
    private static func loadedStore() -> SessionStore {
        let store = SessionStore()
        var ready = false
        store.pollRegistry()
        store.refreshTerminal { ready = true }
        let deadline = Date().addingTimeInterval(8)
        while !ready, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        if let problem = store.terminalProblem { print("Terminal: \(problem)") }
        return store
    }

    private static func list(_ store: SessionStore) {
        let transcripts = TranscriptReader()
        for s in store.sessions {
            let place = s.desktop.map { "D\($0)" } ?? (s.onScreen ? "D?" : "hidden")
            print(String(format: "%-9@ %6d  %-7@ %-22@ %@  (%@)", "\(s.state)" as NSString, s.pid, place as NSString,
                         (s.tmuxSession ?? "not in tmux") as NSString, s.name as NSString, s.folder as NSString))
            if let details = transcripts.details(sessionId: s.sessionId, cwd: s.cwd) { print("          " + details.text) }
        }
    }

    private static func usage() {
        switch UsageFetcher.fetch() {
        case .success(let u):
            for w in u.windows { print("\(w.label): \(Int(w.percent))% resets \(w.resetsAt.map { "\($0)" } ?? "-")") }
            if let used = u.extraUsed, let limit = u.extraLimit { print("Extra usage: \(used) / \(limit) \(u.currency)") }
            print("plan: \(u.plan ?? "-")")
        case .failure(let error):
            print("error: \(error.localizedDescription)")
        }
    }

    private static func reorganise(execute: Bool) {
        let store = loadedStore()
        do {
            let plan = try Reorganizer.plan(sessions: store.sessions, screens: ScreenInfo.all(), capacity: Settings.savedWindowsPerDesktop)
            print(plan.description)
            print("\(plan.changes.count) window(s) would switch session")
            if execute {
                let spread = try Reorganizer.spreadOut(screens: ScreenInfo.all(), capacity: Settings.savedWindowsPerDesktop,
                                                       openMissing: Settings.savedOpensWindows)
                print("opened \(spread.opened) window(s)" + (spread.note.map { " · " + $0 } ?? ""))
                let paired = try Reorganizer.pairUp(screens: ScreenInfo.all(), capacity: Settings.savedWindowsPerDesktop)
                print("paired up \(paired) window(s)")
                let fresh = try Reorganizer.plan(sessions: loadedStore().sessions, screens: ScreenInfo.all(), capacity: Settings.savedWindowsPerDesktop)
                print(try Reorganizer.execute(fresh).message)
            }
        } catch {
            print("error: \(error.localizedDescription)")
        }
    }

    /// Each desktop, whether something's open on it, and which chats its windows show.
    private static func desktops() {
        let busy = Desktops.occupied()
        let viewers: [Viewer] = ((try? Reorganizer.desktopGroups()) ?? []).flatMap { $0 }
        let hidden = Set(Tmux.sessionNames()).subtracting(Tmux.clients().map(\.session)).sorted()
        for display in SkyLight.displays() {
            for (n, desktop) in display.desktops.enumerated() {
                let here = viewers.filter { $0.space == desktop.id }.map(\.session)
                print("Desktop \(n + 1)\(desktop.id == display.current ? " (current)" : ""): \(busy.contains(desktop.id) ? "in use" : "empty")  \(here.joined(separator: " "))")
            }
        }
        print("No window: \(hidden.isEmpty ? "none" : hidden.joined(separator: " "))")
        print("Accessibility: \(Desktops.canPressKeys(ask: false) ? "allowed" : "not allowed")")
    }

    private static func moveToTmux(pid: Int32) {
        let store = loadedStore()
        guard let session = store.sessions.first(where: { $0.pid == pid }) else { print("no session with pid \(pid)"); return }
        do {
            try Migration.moveIntoTmux(session)
            print("restarting \(session.name) inside tmux")
        } catch {
            print("error: \(error.localizedDescription)")
        }
    }
}
