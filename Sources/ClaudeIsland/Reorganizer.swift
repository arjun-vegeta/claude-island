import AppKit

struct ScreenInfo {
    let uuid: String
    /// Visible frame (no menu bar or Dock) in global top-left coordinates.
    let visible: CGRect
    let isMain: Bool

    /// Call on the main thread.
    static func all() -> [ScreenInfo] {
        guard let mainHeight = NSScreen.screens.first?.frame.maxY else { return [] }
        return NSScreen.screens.enumerated().compactMap { index, screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
            let v = screen.visibleFrame
            return ScreenInfo(uuid: CFUUIDCreateString(nil, uuid) as String,
                              visible: CGRect(x: v.minX, y: mainHeight - v.maxY, width: v.width, height: v.height),
                              isMain: index == 0)
        }
    }
}

enum ReorgError: LocalizedError {
    case nothing(String)
    var errorDescription: String? {
        switch self { case .nothing(let message): return message }
    }
}

/// A Terminal window showing a tmux session: one slot Reorganise can fill.
struct Viewer {
    let windowID: Int
    let clientTTY: String
    let session: String
    let space: UInt64
    let display: String
    /// Mission Control position of its desktop.
    let order: Int
    let desktopNumber: Int
    let frame: CGRect
}

struct ReorgPlan {
    let assignments: [(viewer: Viewer, session: String)]
    let bounds: [(windowID: Int, bounds: CGRect)]
    let names: [String: String]
    let notes: [String]

    var changes: [(clientTTY: String, session: String)] {
        assignments.filter { $0.viewer.session != $0.session }.map { ($0.viewer.clientTTY, $0.session) }
    }

    var description: String {
        let byDesktop = Dictionary(grouping: assignments, by: \.viewer.desktopNumber)
        let lines = byDesktop.keys.sorted().map { number in
            "Desktop \(number): " + byDesktop[number]!.map { a in
                (names[a.session] ?? a.session) + (a.viewer.session == a.session ? "" : " (swapped in)")
            }.joined(separator: "  |  ")
        }
        return (lines + notes).joined(separator: "\n")
    }
}

/// Reorganise for tmux sessions: Terminal windows stay where they are, and each one is pointed at a
/// different session. Running sessions fill the earliest desktops that hold two windows, in pairs.
enum Reorganizer {
    /// Terminal windows showing tmux sessions, grouped by desktop in Mission Control order, each
    /// group left to right. Blocking (AppleScript + tmux): call off the main thread.
    static func desktopGroups() throws -> [[Viewer]] {
        let clients = Tmux.clients()
        guard !clients.isEmpty else {
            throw ReorgError.nothing("None of your sessions run in tmux yet. Press “Move into tmux” first.")
        }
        let windows = try TerminalBridge.listWindows()
        let displays = SkyLight.displays()

        var viewers: [Viewer] = []
        for w in windows where !w.miniaturized {
            guard let tab = w.tabs.first(where: \.selected), let client = clients.first(where: { $0.tty == tab.tty }) else { continue }
            let spaces = SkyLight.spaces(forWindow: CGWindowID(w.id))
            guard spaces.count == 1,
                  let display = displays.first(where: { $0.desktops.contains { $0.id == spaces[0] } }),
                  let order = display.spaces.firstIndex(where: { $0.id == spaces[0] }),
                  let number = display.desktops.firstIndex(where: { $0.id == spaces[0] }) else { continue }
            viewers.append(Viewer(windowID: w.id, clientTTY: client.tmuxTTY, session: client.session, space: spaces[0],
                                  display: display.uuid, order: order, desktopNumber: number + 1, frame: w.bounds))
        }
        guard !viewers.isEmpty else { throw ReorgError.nothing("No Terminal window is showing a tmux session.") }

        let displayRank = Dictionary(uniqueKeysWithValues: displays.enumerated().map { ($1.uuid, $0) })
        return Dictionary(grouping: viewers, by: \.space).values
            .map { $0.sorted(by: gridOrder) }
            .sorted { (displayRank[$0[0].display] ?? 0, $0[0].order) < (displayRank[$1[0].display] ?? 0, $1[0].order) }
    }

    /// Reading order on a desktop: top row first, each row left to right.
    static func gridOrder(_ a: Viewer, _ b: Viewer) -> Bool { gridOrder(a.frame, b.frame) }
    static func gridOrder(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minY - b.minY) > 40 ? a.minY < b.minY : a.minX < b.minX
    }

    /// Slot `slot` of a desktop laid out for `capacity` windows: 2 side by side, 4 in a 2 × 2 grid, or
    /// 6 in 2 rows of 3.
    static func cell(_ visible: CGRect, slot: Int, of capacity: Int) -> CGRect {
        let columns = capacity == 6 ? 3 : 2
        let rows = max(1, capacity / columns)
        let width = (visible.width / CGFloat(columns)).rounded(.down)
        let height = (visible.height / CGFloat(rows)).rounded(.down)
        let column = slot % columns, row = slot / columns
        // The last column and row take the leftover pixels, so the grid fills the screen exactly.
        let x = visible.minX + CGFloat(column) * width
        let y = visible.minY + CGFloat(row) * height
        return CGRect(x: x, y: y, width: column == columns - 1 ? visible.maxX - x : width,
                      height: row == rows - 1 ? visible.maxY - y : height)
    }

    /// Bounds for `windows`, in reading order, filling a desktop's slots from the top left.
    static func tile(_ windows: [Int], on visible: CGRect, capacity: Int) -> [(windowID: Int, bounds: CGRect)] {
        windows.prefix(capacity).enumerated().map { ($1, cell(visible, slot: $0, of: capacity)) }
    }

    /// Gives every chat a window, `capacity` to a desktop. Windows past the first `capacity` on a crowded
    /// desktop always move (say, after switching from 4 windows per desktop to 2); chats with no window
    /// get one only with `openMissing`. Each goes onto a desktop with room first, then onto
    /// empty desktops of the main display (reached with Ctrl+→, which needs Accessibility). Afterwards you're
    /// taken back to the desktop you started on. Returns how many windows opened and a note about
    /// anything left over. Blocking: call off the main thread.
    static func spreadOut(screens: [ScreenInfo], capacity: Int, openMissing: Bool) throws -> (opened: Int, note: String?) {
        var groups = try desktopGroups()
        let shown = Set(Tmux.clients().map(\.session))
        var waiting: [(session: String, oldWindow: Int?)] = openMissing
            ? Tmux.sessionNames().filter { !shown.contains($0) }.map { ($0, nil) } : []
        for (k, group) in groups.enumerated() where group.count > capacity {
            waiting += group.dropFirst(capacity).map { ($0.session, $0.windowID) }
            groups[k] = Array(group.prefix(capacity))
        }
        guard !waiting.isEmpty else { return (0, nil) }

        let displays = SkyLight.displays()
        let start = SkyLight.activeSpace()
        let jumps = groups.joined().map { (id: $0.windowID, space: $0.space) }
        var opened = 0
        defer {
            if opened > 0, let display = displays.first(where: { $0.spaces.contains { $0.id == start } }) {
                _ = Desktops.go(to: start, on: display, windows: jumps)
            }
        }

        enum Placed { case here(Int), elsewhere, failed }
        // Opens a window for `item` on the desktop you're on, which should be `space`.
        func place(_ item: (session: String, oldWindow: Int?), on space: UInt64) -> Placed {
            let count = { Tmux.clients().filter { $0.session == item.session }.count }
            let before = count()
            guard let id = try? TerminalBridge.openWindow(running: Tmux.attachCommand(item.session)) else { return .failed }
            let deadline = Date().addingTimeInterval(4)
            while count() <= before, Date() < deadline { usleep(100_000) }
            guard count() > before else { return .failed }
            guard SkyLight.spaces(forWindow: CGWindowID(id)).contains(space) else {
                // Landed on another desktop. A moved window closes again (its old one still shows the
                // chat); a chat that had no window keeps this one, since closing it would end the chat.
                if item.oldWindow != nil { try? TerminalBridge.close(windowID: id) }
                return .elsewhere
            }
            if let old = item.oldWindow { try? TerminalBridge.close(windowID: old) }
            return .here(id)
        }
        func screen(for display: String) -> ScreenInfo? {
            screens.first { $0.uuid == display } ?? screens.first(where: \.isMain)
        }
        var switchFailed: String {
            "macOS didn't switch desktops, so \(waiting.count) chat\(waiting.count == 1 ? "" : "s") still \(waiting.count == 1 ? "has" : "have") no window"
        }

        // Onto desktops with room.
        for group in groups where group.count < capacity && !waiting.isEmpty {
            let anchor = group[0]
            guard let display = displays.first(where: { $0.uuid == anchor.display }) ?? displays.first,
                  let visible = screen(for: anchor.display)?.visible,
                  Desktops.go(to: anchor.space, on: display, windows: [(anchor.windowID, anchor.space)]) else { return (opened, switchFailed) }
            var here = group.map(\.windowID)
            defer { try? TerminalBridge.setBounds(tile(here, on: visible, capacity: capacity)) }
            while here.count < capacity, !waiting.isEmpty {
                let item = waiting.removeFirst()
                switch place(item, on: anchor.space) {
                case .here(let id):
                    opened += 1
                    here.append(id)
                case .elsewhere:
                    if item.oldWindow == nil { opened += 1 }
                    return (opened, switchFailed)
                case .failed:
                    return (opened, "Couldn't open a window for \(item.session)")
                }
            }
        }
        guard !waiting.isEmpty else { return (opened, nil) }

        // Then empty desktops, `capacity` windows each.
        guard Desktops.canPressKeys(ask: true) else {
            return (opened, "Allow Claude Island in System Settings › Privacy & Security › Accessibility, then Reorganise again to give \(waiting.count) more chat\(waiting.count == 1 ? "" : "s") a window")
        }
        let mainID = screens.first(where: \.isMain)?.uuid
        guard let display = displays.first(where: { $0.uuid == mainID }) ?? displays.first,
              let visible = screen(for: display.uuid)?.visible else { return (opened, nil) }
        let busy = Desktops.occupied()
        for desktop in display.desktops where !busy.contains(desktop.id) && !waiting.isEmpty {
            guard Desktops.go(to: desktop.id, on: display, windows: jumps) else { return (opened, switchFailed) }
            var here: [Int] = []
            defer { try? TerminalBridge.setBounds(tile(here, on: visible, capacity: capacity)) }
            while here.count < capacity, !waiting.isEmpty {
                let item = waiting.removeFirst()
                switch place(item, on: desktop.id) {
                case .here(let id): here.append(id); opened += 1
                case .elsewhere:
                    if item.oldWindow == nil { opened += 1 }
                    return (opened, switchFailed)
                case .failed:
                    return (opened, "Couldn't open a window for \(item.session)")
                }
            }
        }
        guard waiting.isEmpty else {
            let needed = (waiting.count + capacity - 1) / capacity
            return (opened, "No empty desktops left: add \(needed) in Mission Control, then Reorganise again")
        }
        return (opened, nil)
    }

    /// Fills every desktop (except perhaps the last) to `capacity` windows. A desktop with room gets
    /// windows from the last desktops: a new window opens there showing the same session, then the
    /// old one closes. The session never stops, since for a moment two windows show it. Returns how
    /// many windows moved. Blocking: call off the main thread.
    @discardableResult
    static func pairUp(screens: [ScreenInfo], capacity: Int) throws -> Int {
        var groups = try desktopGroups()
        var moved = 0
        var i = 0, j = groups.count - 1
        while i < j {
            if groups[i].count >= capacity { i += 1; continue }
            if groups[j].isEmpty { j -= 1; continue }
            let anchor = groups[i][0]
            let donor = groups[j].removeLast()
            guard let screen = screens.first(where: { $0.uuid == anchor.display }) ?? screens.first(where: \.isMain) else { break }

            // Go to the anchor's desktop, where the new window will open.
            try TerminalBridge.focus(windowID: anchor.windowID, tab: nil)
            let deadline = Date().addingTimeInterval(3)
            while SkyLight.activeSpace() != anchor.space, Date() < deadline { usleep(50_000) }
            // If macOS didn't switch, the window would open on whatever desktop you're on and pile up there.
            guard SkyLight.activeSpace() == anchor.space else { break }
            usleep(300_000)

            guard let newWindow = try TerminalBridge.openWindow(running: Tmux.attachCommand(donor.session)) else { break }
            let attachDeadline = Date().addingTimeInterval(4)
            while Tmux.clients().filter({ $0.session == donor.session }).count < 2, Date() < attachDeadline { usleep(100_000) }
            guard Tmux.clients().filter({ $0.session == donor.session }).count >= 2 else { break }
            // Same check once it's open: if it landed elsewhere, close it again; the donor still shows the session.
            guard SkyLight.spaces(forWindow: CGWindowID(newWindow)).contains(anchor.space) else {
                try? TerminalBridge.close(windowID: newWindow)
                break
            }

            try TerminalBridge.setBounds(tile(groups[i].map(\.windowID) + [newWindow], on: screen.visible, capacity: capacity))
            try TerminalBridge.close(windowID: donor.windowID)
            groups[i].append(donor)
            moved += 1
        }
        return moved
    }

    /// Blocking (AppleScript + tmux): call off the main thread.
    static func plan(sessions: [ClaudeSession], screens: [ScreenInfo], capacity: Int) throws -> ReorgPlan {
        let desktops = try desktopGroups()
        let slotIndex = Dictionary(desktops.joined().enumerated().map { ($1.session, $0) }, uniquingKeysWith: min)

        // Sessions in the order they should appear: needs-you, running, finished, idle. Ties keep
        // their current position so nothing shuffles for no reason.
        var seen = Set<String>()
        let ranked = sessions.compactMap { s -> ClaudeSession? in
            guard let t = s.tmuxSession, seen.insert(t).inserted else { return nil }
            return s
        }.sorted { a, b in
            if a.state != b.state { return a.state < b.state }
            return (slotIndex[a.tmuxSession!] ?? .max) < (slotIndex[b.tmuxSession!] ?? .max)
        }

        // Running sessions go to the first desktops with at least two windows, so none sits alone.
        let activeCount = ranked.filter(\.isActive).count
        var first: [Viewer] = []
        for group in desktops where group.count >= 2 && first.count < activeCount { first += group.prefix(capacity) }
        let firstIDs = Set(first.map(\.windowID))
        let slots = first + desktops.joined().filter { !firstIDs.contains($0.windowID) }
        let assignments = zip(slots, ranked).map { (viewer: $0, session: $1.tmuxSession!) }

        var bounds: [(windowID: Int, bounds: CGRect)] = []
        for group in desktops where group.count <= capacity {
            guard let screen = screens.first(where: { $0.uuid == group[0].display }) ?? screens.first(where: \.isMain) else { continue }
            bounds += tile(group.map(\.windowID), on: screen.visible, capacity: capacity)
        }

        var notes: [String] = []
        let notInTmux = sessions.filter { !$0.inTmux }.count
        if notInTmux > 0 { notes.append("\(notInTmux) session\(notInTmux == 1 ? " isn't" : "s aren't") in tmux yet") }
        let hidden = ranked.count - assignments.count
        if hidden > 0 { notes.append("\(hidden) more than there are windows") }

        var names: [String: String] = [:]
        for s in ranked { names[s.tmuxSession!] = s.name }
        return ReorgPlan(assignments: assignments, bounds: bounds, names: names, notes: notes)
    }

    /// Returns the message to show and how many windows switched session.
    static func execute(_ plan: ReorgPlan) throws -> (message: String, switched: Int) {
        let changes = plan.changes
        guard Tmux.switchClients(changes) else { throw ReorgError.nothing("tmux didn't accept the switch.") }
        try TerminalBridge.setBounds(plan.bounds)
        let head = changes.isEmpty ? "Already in order" : "Done · \(changes.count) window\(changes.count == 1 ? "" : "s") switched"
        return (([head] + plan.notes).joined(separator: " · "), changes.count)
    }

    /// Opens a new Terminal window on this desktop running Claude Code inside tmux. If the desktop has
    /// room in its layout, the new window takes the next free slot. Blocking: call off the main thread.
    static func openNewChat(screens: [ScreenInfo], capacity: Int) throws {
        let active = SkyLight.activeSpace()
        let here = (try? TerminalBridge.listWindows())?.filter {
            !$0.miniaturized && SkyLight.spaces(forWindow: CGWindowID($0.id)) == [active]
        } ?? []
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard let id = try TerminalBridge.openWindow(running: shellQuote(Tmux.launcher), in: home),
              (1..<capacity).contains(here.count) else { return }
        let display = SkyLight.displays().first { $0.spaces.contains { $0.id == active } }?.uuid
        guard let screen = screens.first(where: { $0.uuid == display }) ?? screens.first(where: \.isMain) else { return }
        let ordered = here.sorted { gridOrder($0.bounds, $1.bounds) }.map(\.id)
        try TerminalBridge.setBounds(tile(ordered + [id], on: screen.visible, capacity: capacity))
    }
}

/// One-time move of a session that was started before the tmux setup: quit it and resume the same
/// conversation inside tmux, in the same Terminal tab.
enum Migration {
    /// Flags worth carrying over, and whether each takes a value.
    private static let keptFlags: [String: Bool] = [
        "--model": true, "--effort": true, "--permission-mode": true, "--agent": true, "--add-dir": true,
        "--chrome": false, "--ide": false, "--verbose": false,
        "--dangerously-skip-permissions": false, "--allow-dangerously-skip-permissions": false,
    ]

    /// Blocking: call off the main thread.
    static func moveIntoTmux(_ s: ClaudeSession) throws {
        guard !s.inTmux else { return }
        guard s.state == .idle || s.state == .finished else { throw ReorgError.nothing("\(s.name) is busy, so it was left as is.") }
        guard let window = s.windowID, let tab = s.tabIndex else { throw ReorgError.nothing("Couldn't find \(s.name)'s window.") }

        let flags = kept(arguments(of: s.pid).dropFirst())
        guard kill(s.pid, SIGTERM) == 0 else { throw ReorgError.nothing("Couldn't stop \(s.name).") }
        let deadline = Date().addingTimeInterval(10)
        while kill(s.pid, 0) == 0, Date() < deadline { usleep(100_000) }
        guard kill(s.pid, 0) != 0 else { throw ReorgError.nothing("\(s.name) didn't quit, so it was left as is.") }
        usleep(400_000)

        let command = (["cd", shellQuote(s.cwd), "&&", shellQuote(Tmux.launcher), "--resume", shellQuote(s.sessionId)]
            + flags.map(shellQuote)).joined(separator: " ")
        try TerminalBridge.type(command, windowID: window, tab: tab)
    }

    private static func kept(_ args: ArraySlice<String>) -> [String] {
        var out: [String] = []
        var it = args.makeIterator()
        while let arg = it.next() {
            let name = String(arg.split(separator: "=", maxSplits: 1).first ?? "")
            guard let takesValue = keptFlags[name] else { continue }
            out.append(arg)
            if takesValue, !arg.contains("="), let value = it.next() { out.append(value) }
        }
        return out
    }

    private static func arguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return [] }
        let argc = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
        var i = 4
        while i < size, buffer[i] != 0 { i += 1 }   // executable path
        while i < size, buffer[i] == 0 { i += 1 }   // padding
        var args: [String] = []
        while args.count < argc, i < size {
            let start = i
            while i < size, buffer[i] != 0 { i += 1 }
            args.append(String(decoding: buffer[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }
}
