import AppKit

struct ClaudeSession: Identifiable, Equatable {
    enum State: Int, Comparable {
        case needsYou, running, finished, idle
        static func < (a: State, b: State) -> Bool { a.rawValue < b.rawValue }
    }

    let pid: Int32
    let sessionId: String
    let cwd: String
    let name: String
    let folder: String
    let state: State
    let waitingFor: String?
    let since: Date
    /// How long the last turn ran, for finished sessions.
    let lastRun: TimeInterval?
    let tty: String?
    /// The tmux session it runs in; nil for sessions started before Claude Island's tmux setup.
    let tmuxSession: String?
    /// The Terminal window showing it (for tmux sessions, the window whose client shows it).
    let windowID: Int?
    let tabIndex: Int?
    let desktop: Int?
    /// The cmux terminal it runs in, for chats started in cmux.
    let cmuxSurface: String?
    /// Idle, seen, and finished within the last six hours: something you're in the middle of.
    /// (Finished sessions you haven't opened yet are "done" instead, however long ago.)
    let recent: Bool

    var id: Int32 { pid }
    var isActive: Bool { state == .running || state == .needsYou }
    var inTmux: Bool { tmuxSession != nil }
    var inCmux: Bool { cmuxSurface != nil }
    var onScreen: Bool { windowID != nil }
}

struct SessionEvent: Identifiable, Equatable {
    enum Kind: Equatable {
        case finished(TimeInterval)
        case needsInput(String)
    }

    let id = UUID()
    let pid: Int32
    let name: String
    let kind: Kind
    let desktop: Int?
}

/// Merges the claude binary's session registry with tmux, Terminal's windows and cmux's terminals,
/// and turns status changes into "finished" / "needs you" events.
final class SessionStore: ObservableObject {
    /// A session that finished within this long counts as recent rather than idle.
    static let recentWindow: TimeInterval = 6 * 60 * 60

    @Published private(set) var sessions: [ClaudeSession] = []
    @Published private(set) var terminalProblem: String?
    /// Model, effort and context for each chat, by session id, from its transcript.
    @Published private(set) var details: [String: SessionDetails] = [:]

    var onEvent: ((SessionEvent) -> Void)?
    /// Poll Terminal more often while the island is open.
    var fastTerminalRefresh = false

    private var entries: [RegistryEntry] = []
    private var windows: [TerminalWindow] = []
    private var panes: [Tmux.Pane] = []
    private var clients: [Tmux.Client] = []
    private var cmuxTerminals: [CmuxTerminal] = []
    private var desktopOf: [Int: Int] = [:]
    private var lastStatus: [Int32: SessionStatus] = [:]
    private var busySince: [Int32: Date] = [:]
    private var lastRun: [Int32: TimeInterval] = [:]
    private var unseen: Set<Int32> = []
    private var seeded = false
    private let terminalQueue = DispatchQueue(label: "claude-island.terminal")
    private var terminalBusy = false
    private var lastTerminalRefresh = Date.distantPast
    private var timer: Timer?
    private let transcripts = TranscriptReader()
    private let detailsQueue = DispatchQueue(label: "claude-island.details")
    private var detailsBusy = false
    private var lastDetailsRefresh = Date.distantPast

    func start() {
        pollRegistry()
        refreshTerminal()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func tick() {
        pollRegistry()
        if Date().timeIntervalSince(lastTerminalRefresh) >= (fastTerminalRefresh ? 2 : 6) { refreshTerminal() }
        if Date().timeIntervalSince(lastDetailsRefresh) >= (fastTerminalRefresh ? 3 : 10) { refreshDetails() }
    }

    /// Re-reads the transcripts that changed since last time, off the main thread.
    func refreshDetails() {
        guard !detailsBusy else { return }
        lastDetailsRefresh = Date()
        detailsBusy = true
        let chats = entries.map { ($0.sessionId, $0.cwd) }
        detailsQueue.async {
            var found: [String: SessionDetails] = [:]
            for (id, cwd) in chats { found[id] = self.transcripts.details(sessionId: id, cwd: cwd) }
            self.transcripts.keep(Set(chats.map(\.0)))
            DispatchQueue.main.async {
                self.detailsBusy = false
                if self.details != found { self.details = found }
            }
        }
    }

    func pollRegistry() {
        let fresh = Registry.liveSessions()
        entries = fresh
        rebuild()
        detectTransitions(fresh)
    }

    func refreshTerminal(then done: (() -> Void)? = nil) {
        guard !terminalBusy else { return }
        lastTerminalRefresh = Date()
        terminalBusy = true
        // cmux is only asked when a chat runs in it, so nobody else is asked to let the island control it.
        let readCmux = entries.contains { $0.cmuxSurface != nil }
        terminalQueue.async {
            let result = Result { try TerminalBridge.listWindows() }
            let panes = Tmux.panes()
            let clients = Tmux.clients()
            let desktops = (try? result.get()).map { SkyLight.desktopNumbers(for: $0.map(\.id)) } ?? [:]
            let cmux = readCmux ? Result { try Cmux.listTerminals() } : .success([])
            DispatchQueue.main.async {
                self.terminalBusy = false
                self.panes = panes
                self.clients = clients
                if case .success(let list) = cmux { self.cmuxTerminals = list }
                switch result {
                case .success(let list):
                    self.windows = list
                    self.desktopOf = desktops
                    self.terminalProblem = nil
                    self.markFrontmostSeen()
                case .failure(let error):
                    self.terminalProblem = "\(error)"
                }
                if case .failure(let error) = cmux, self.terminalProblem == nil { self.terminalProblem = "\(error)" }
                self.markFrontCmuxSeen()
                self.rebuild()
                done?()
            }
        }
    }

    /// The user looked at it (clicked it in the island or brought its window forward).
    func markSeen(_ pid: Int32) {
        guard unseen.remove(pid) != nil else { return }
        rebuild()
    }

    // MARK: - Internals

    private func detectTransitions(_ fresh: [RegistryEntry]) {
        for e in fresh {
            let previous = lastStatus[e.pid]
            if e.status != .idle, busySince[e.pid] == nil { busySince[e.pid] = e.statusSince }
            if e.status == .busy, unseen.remove(e.pid) != nil { rebuild() }

            if seeded, let previous, previous != e.status {
                if e.status == .idle {
                    let ran = e.statusSince.timeIntervalSince(busySince[e.pid] ?? e.statusSince)
                    lastRun[e.pid] = ran
                    if ran >= 3, !isFrontmost(e) {
                        unseen.insert(e.pid)
                        rebuild()
                        emit(e, .finished(ran))
                    }
                } else if e.status == .waiting, !isFrontmost(e) {
                    emit(e, .needsInput(e.waitingFor ?? "input"))
                }
            }
            if e.status == .idle { busySince[e.pid] = nil }
            lastStatus[e.pid] = e.status
        }
        let alive = Set(fresh.map(\.pid))
        lastStatus = lastStatus.filter { alive.contains($0.key) }
        busySince = busySince.filter { alive.contains($0.key) }
        lastRun = lastRun.filter { alive.contains($0.key) }
        unseen.formIntersection(alive)
        seeded = true
    }

    private func emit(_ e: RegistryEntry, _ kind: SessionEvent.Kind) {
        guard let session = sessions.first(where: { $0.pid == e.pid }) else { return }
        onEvent?(SessionEvent(pid: e.pid, name: session.name, kind: kind, desktop: session.desktop))
    }

    /// The tty of the claude process shown in a Terminal tab: the tab's own tty, or, when the tab
    /// is a tmux client, the tty of the pane its session runs in.
    private func claudeTTY(shownIn tabTTY: String) -> String? {
        guard let client = clients.first(where: { $0.tty == tabTTY }) else { return tabTTY }
        return panes.first { $0.session == client.session }?.tty
    }

    /// The cmux terminal you're typing into, when cmux is the frontmost app.
    private var frontCmuxSurface: String? {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Cmux.bundleID else { return nil }
        return cmuxTerminals.first(where: \.inFront)?.id
    }

    /// True when this session is in the tab right in front of the user.
    private func isFrontmost(_ e: RegistryEntry) -> Bool {
        if let surface = e.cmuxSurface { return surface == frontCmuxSurface }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == TerminalBridge.bundleID,
              let tab = windows.first?.tabs.first(where: \.selected) else { return false }
        return e.tty != nil && claudeTTY(shownIn: tab.tty) == e.tty
    }

    private func markFrontCmuxSeen() {
        guard let surface = frontCmuxSurface else { return }
        for e in entries where e.cmuxSurface == surface { unseen.remove(e.pid) }
    }

    private func markFrontmostSeen() {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == TerminalBridge.bundleID,
              let tab = windows.first?.tabs.first(where: \.selected),
              let tty = claudeTTY(shownIn: tab.tty) else { return }
        for e in entries where e.tty == tty { unseen.remove(e.pid) }
    }

    private func rebuild() {
        var tabByTTY: [String: (window: TerminalWindow, tab: Int, title: String)] = [:]
        for w in windows {
            for (i, t) in w.tabs.enumerated() { tabByTTY[t.tty] = (w, i + 1, t.title) }
        }
        let paneByTTY = Dictionary(panes.map { ($0.tty, $0) }, uniquingKeysWith: { a, _ in a })
        let cmuxByID = Dictionary(cmuxTerminals.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        let list = entries.map { e -> ClaudeSession in
            let pane = e.tty.flatMap { paneByTTY[$0] }
            // A workspace with just this chat in it carries the chat's title in cmux's sidebar.
            let cmuxTitle = e.cmuxSurface.flatMap { cmuxByID[$0] }.flatMap { $0.workspaceTerminals == 1 ? $0.workspaceName : nil }
            // A tmux session is on screen in the frontmost Terminal window whose client shows it.
            let shownIn = pane.flatMap { pane in
                clients.filter { $0.session == pane.session }.compactMap { tabByTTY[$0.tty] }.min { $0.window.zIndex < $1.window.zIndex }
            } ?? (pane == nil ? e.tty.flatMap { tabByTTY[$0] } : nil)
            let state: ClaudeSession.State
            switch e.status {
            case .waiting: state = .needsYou
            case .busy: state = .running
            case .idle: state = unseen.contains(e.pid) ? .finished : .idle
            }
            return ClaudeSession(
                pid: e.pid,
                sessionId: e.sessionId,
                cwd: e.cwd,
                name: displayName(e, title: pane?.title ?? shownIn?.title ?? cmuxTitle),
                folder: e.cwd == home ? "~" : (e.cwd as NSString).lastPathComponent,
                state: state,
                waitingFor: e.waitingFor,
                since: e.status == .idle ? e.statusSince : (busySince[e.pid] ?? e.statusSince),
                lastRun: lastRun[e.pid],
                tty: e.tty,
                tmuxSession: pane?.session,
                windowID: shownIn?.window.id,
                tabIndex: shownIn?.tab,
                desktop: shownIn.flatMap { desktopOf[$0.window.id] },
                cmuxSurface: e.cmuxSurface,
                recent: state == .idle && Date().timeIntervalSince(e.statusSince) < SessionStore.recentWindow
            )
        }
        let sorted = list.sorted { a, b in
            if a.state != b.state { return a.state < b.state }
            return a.isActive ? a.since < b.since : a.since > b.since
        }
        if sorted != sessions { sessions = sorted }
        if let newest = entries.max(by: { $0.started < $1.started }), (newest.cmuxSurface != nil) != Self.newChatsInCmux {
            Self.newChatsInCmux = newest.cmuxSurface != nil
        }
    }

    /// Every chat runs in cmux (with none open, the newest one did), so the parts of the island that
    /// arrange Terminal windows have nothing to do.
    var onlyCmux: Bool {
        sessions.isEmpty ? Self.newChatsInCmux : sessions.allSatisfy(\.inCmux)
    }

    /// New chats open where your newest chat runs: in cmux or in Terminal. Saved, so it still holds
    /// when no chat is open.
    static var newChatsInCmux: Bool {
        get { Settings.defaults.bool(forKey: "newChatsInCmux") }
        set { Settings.defaults.set(newValue, forKey: "newChatsInCmux") }
    }

    /// Names the user picked win; otherwise Claude's own title ("✳ Fix the login bug").
    private func displayName(_ e: RegistryEntry, title: String?) -> String {
        if e.nameIsUser, !e.name.isEmpty { return e.name }
        if let title = title?.replacingOccurrences(of: #"^[^\p{L}\p{N}]{1,3}\s+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces), !title.isEmpty, !Self.isHostName(title) { return title }
        return e.name.isEmpty ? "Session \(e.pid)" : e.name
    }

    /// tmux titles a pane with the host name until the program inside sets its own title.
    private static func isHostName(_ title: String) -> Bool {
        let host = ProcessInfo.processInfo.hostName
        return title == host || title == host.split(separator: ".").first.map(String.init)
    }
}
