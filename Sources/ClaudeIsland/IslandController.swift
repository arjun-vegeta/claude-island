import AppKit
import Combine
import SwiftUI

enum IslandLayout {
    static let panelSize = CGSize(width: 680, height: 720)
    static let expandedWidth: CGFloat = 560
    static let toastWidth: CGFloat = 360
    static let toastBody: CGFloat = 46
    /// Collapsed: room for Clawd lurking beside the notch.
    static let clawdWing: CGFloat = 30
    static let ear: CGFloat = 8
    static let usageHeight: CGFloat = 72
    /// "Last checked 12m ago", under the meters when the latest check failed.
    static let staleLine: CGFloat = 18
    /// The list: sections of two columns. Working sessions are cards; done and idle ones are slim rows.
    static let sectionLabel: CGFloat = 24
    static let sectionLabelGap: CGFloat = 6
    static let cardHeight: CGFloat = 50
    /// Cards and rows grow by a line when they show the chat's model, effort and context.
    static let detailsLine: CGFloat = 14
    static let cardGap: CGFloat = 8
    static let rowHeight: CGFloat = 30
    static let rowGap: CGFloat = 2
    static let listBottom: CGFloat = 12
    /// Beyond this the list scrolls.
    static let maxListHeight: CGFloat = 400
    static let emptyHeight: CGFloat = 92
    static let bannerHeight: CGFloat = 34
    static let footerHeight: CGFloat = 56
    static let noteHeight: CGFloat = 22
    /// The search line that appears when you type with the island open.
    static let searchHeight: CGFloat = 40
    /// The settings page: four titled groups of full-width rows, twelve rows in all.
    static let settingsRow: CGFloat = 36
    static let settingsSections = 4
    static let settingsRows = 12
    static var settingsHeight: CGFloat {
        CGFloat(settingsSections) * (sectionLabel + sectionLabelGap) + CGFloat(settingsRows) * settingsRow + listBottom + 1
    }
}

struct NotchGeometry: Equatable {
    var screenFrame: NSRect = .zero
    var notchWidth: CGFloat = 185
    var notchHeight: CGFloat = 32
    var notchMidX: CGFloat = 0
}

final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = true
    }

    /// Only while the island is open, so typing searches the sessions. The panel never activates the
    /// app, and gives the keyboard back to the terminal when the island closes.
    var takesKeyboard = false
    override var canBecomeKey: Bool { takesKeyboard }
    override var canBecomeMain: Bool { false }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    private var moveTracking: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // The island never becomes the active app, and AppKit only sends mouse moves to an inactive app's
    // window through an "active always" tracking area. Without it, hover highlights lag behind the cursor.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let moveTracking { removeTrackingArea(moveTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        moveTracking = area
    }
}

final class IslandController: NSObject, ObservableObject {
    enum Mode: Equatable {
        case collapsed
        case expanded
        case toast(SessionEvent)
        case working(String, done: Bool)
    }

    @Published private(set) var mode: Mode = .collapsed
    @Published private(set) var geometry = NotchGeometry()
    @Published private(set) var note: String?
    /// Showing the "restart these sessions inside tmux?" question in the footer.
    @Published var confirmingMove = false
    /// The island shows the settings page instead of the sessions.
    @Published var showingSettings = false {
        willSet {
            // The island takes the new page's height, which may be shorter. The pointer is still on the
            // button you just clicked, now below the island; keep it open until the pointer gets back in.
            if newValue != showingSettings, mode == .expanded { holdHeight = max(holdHeight, islandSize.height) }
        }
    }
    /// Height (from the top of the notch) the pointer may be within and keep the island open, after
    /// switching to a shorter page. Nothing is drawn there. Cleared once the pointer is in the island.
    private var holdHeight: CGFloat = 0
    /// Clawd dances in the corner for a moment after a Reorganise that changed something.
    @Published private(set) var celebrating = false
    /// Which side of the notch Clawd lurks on. Between loops he sometimes walks to the other side,
    /// staying hidden for a second as if passing behind the notch.
    enum Side { case left, right }
    /// Now and then he comes all the way out to dance or wave instead of lurking.
    enum LurkAct: Equatable {
        case lurking, dancing, waving
        /// Plays once right of the notch when you start a new chat.
        case racing

        var sprite: String {
            switch self {
            case .lurking: return "lurking"
            case .dancing: return "dancing"
            case .waving: return "waving"
            case .racing: return "racing"
            }
        }

        /// Size relative to lurking Clawd.
        var scale: CGFloat {
            switch self {
            case .lurking: return 1
            case .dancing: return 0.92
            case .waving: return 0.97
            case .racing: return 1   // sized to the room it has instead; see racingHeight
            }
        }

        /// Space between Clawd and the notch: lurking hugs it (tucked 1pt under); dancing and waving
        /// stand 2-4pt clear. The dance frames are wider than Clawd (he sways), so it sits a bit closer.
        var gap: CGFloat {
            switch self {
            case .lurking: return -1
            case .dancing: return 1
            case .waving, .racing: return 3
            }
        }
    }
    @Published private(set) var lurkSide: Side = .left
    @Published private(set) var lurkAct: LurkAct = .lurking
    @Published private(set) var lurkHidden = false
    /// Bumped at every loop so the animation restarts in step with the side switches.
    @Published private(set) var lurkCycle = 0
    private var lurkWork: DispatchWorkItem?
    /// The racing car is as big as fits right of the notch, measured when it starts.
    private var racingHeight: CGFloat = 22
    /// Lurking loops since Clawd last came out; he only dances or waves after at least `minLurks`.
    private var lurksSinceAct = 0
    private let minLurks = 9

    /// Sessions whose "finished" pop-up fired: Clawd waves in place of their blue dot until you click
    /// them or close the island.
    @Published private(set) var waving: Set<Int32> = []
    /// The clickable thing under the pointer (see HoverFrames), and where each one is.
    @Published private(set) var hovered: String?
    var hoverFrames: [String: CGRect] = [:]

    /// What you've typed with the island open; filters the sessions by name and folder.
    @Published private(set) var query = ""
    /// The session Enter opens, moved with the arrow keys. Nil until you type or press an arrow.
    @Published private(set) var selectedPid: Int32?

    let sessions: SessionStore
    let usage: UsageStore
    let settings: Settings

    private var panel: NotchPanel!
    private var monitors: [Any] = []
    private var hoverWork: DispatchWorkItem?
    private var collapseWork: DispatchWorkItem?
    private var toastWork: DispatchWorkItem?
    private var hoveringToast = false
    /// A Move into tmux is running; the island stays put until it ends.
    private var working = false
    private var cancellables: Set<AnyCancellable> = []
    private var safetyTimer: Timer?
    private var noteWork: DispatchWorkItem?
    /// CLAUDE_ISLAND_PIN=1 keeps the island open (for screenshots).
    private let pinned = ProcessInfo.processInfo.environment["CLAUDE_ISLAND_PIN"] == "1"

    static let demoNotification = Notification.Name("com.arjun.claude-island.demo")

    /// Set by the app delegate before `setup()`.
    var updater: Updater!

    /// Restarting for an update now would interrupt you.
    var isBusy: Bool { mode != .collapsed || working }

    init(sessions: SessionStore, usage: UsageStore, settings: Settings) {
        self.sessions = sessions
        self.usage = usage
        self.settings = settings
    }

    func setup() {
        SkyLight.allowCursorChangesInBackground()
        panel = NotchPanel()
        panel.contentView = FirstMouseHostingView(rootView: IslandRootView(controller: self, sessions: sessions, usage: usage,
                                                                           settings: settings, updater: updater))
        layout()
        panel.orderFrontRegardless()

        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in self?.handleMouse() } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .scrollWheel]) { [weak self] event in
            self?.handleMouse()
            return event
        } as Any)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.mode == .expanded, !self.pinned, !self.islandRect.contains(NSEvent.mouseLocation) else { return }
            self.collapse()
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event) == true ? nil : event
        } as Any)
        safetyTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.handleMouse() }

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.layout()
        }
        sessions.onEvent = { [weak self] event in self?.present(event) }
        // `ClaudeIsland --cli demo [dance|wave|race]` asks the running app to show a "finished" pop-up, or
        // to bring Clawd out right away.
        DistributedNotificationCenter.default().addObserver(forName: IslandController.demoNotification, object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            switch note.object as? String {
            case "dance": self.comeOut(.dancing)
            case "wave": self.comeOut(.waving)
            case "race": self.comeOut(.racing)
            default:
                let session = self.sessions.sessions.first { !$0.isActive } ?? self.sessions.sessions.first
                self.present(SessionEvent(pid: session?.pid ?? 0, name: session?.name ?? "Demo session", kind: .finished(272), desktop: session?.desktop))
            }
        }
        sessions.$sessions.sink { [weak self] _ in DispatchQueue.main.async { self?.handleMouse() } }.store(in: &cancellables)
        if pinned { expand() }
        scheduleLurk()
    }

    /// Clawd's size beside the notch for each act.
    func lurkerSize(_ act: LurkAct) -> CGSize {
        let height = act == .racing ? racingHeight : (geometry.notchHeight - 8) * 0.97 * act.scale
        return CGSize(width: max(IslandLayout.clawdWing, height * (Clawd.sprite(act.sprite)?.aspect ?? 1)), height: height)
    }

    /// Free menu-bar width between the notch and the first status-bar icon on its right.
    private func roomRightOfNotch() -> CGFloat {
        let notchRight = geometry.notchMidX + geometry.notchWidth / 2
        let menuBarTop = (NSScreen.screens.first?.frame.maxY ?? 0) - geometry.screenFrame.maxY
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return .greatestFiniteMagnitude
        }
        var room = CGFloat.greatestFiniteMagnitude
        for w in windows where (w[kCGWindowLayer as String] as? Int) == Int(CGWindowLevelForKey(.statusWindow)) {
            guard let dict = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: dict),
                  abs(r.minY - menuBarTop) < 2, r.minX >= notchRight - 1 else { continue }
            room = min(room, r.minX - notchRight)
        }
        return room
    }

    /// Whether `act` fits between the notch and the first status-bar icon on its right.
    private func fitsRightOfNotch(_ act: LurkAct) -> Bool {
        roomRightOfNotch() >= lurkerSize(act).width + act.gap + 2
    }

    /// Clawd slides out from behind the notch, dances once, waves twice or races once, slides back, then
    /// lurks again. The right side is often crowded with status icons, so dancing and waving use the
    /// left when they won't fit; the racing car always plays on the right.
    private func comeOut(_ act: LurkAct) {
        lurkWork?.cancel()
        let returnSide = lurkSide
        if act == .racing {
            lurkSide = .right
            // As tall as the menu bar allows, and no wider than the gap before the first status icon.
            let aspect = Clawd.sprite("racing")?.aspect ?? 1.5
            racingHeight = max(14, min(geometry.notchHeight - 3, (roomRightOfNotch() - act.gap - 2) / aspect))
        } else if lurkSide == .right && !fitsRightOfNotch(act) {
            lurkSide = .left
        }
        let sprite = Clawd.sprite(act.sprite)?.duration ?? 3
        let shown = act == .waving ? 2 * sprite : sprite
        lurksSinceAct = 0
        lurkHidden = false
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            lurkAct = act
            lurkCycle += 1
        }
        lurkWork = after(shown) { [weak self] in
            guard let self else { return }
            withAnimation(.easeIn(duration: 0.3)) { self.lurkHidden = true }
            self.lurkWork = self.after(0.6) { [weak self] in
                guard let self else { return }
                if act == .racing { self.lurkSide = returnSide }
                self.lurkAct = .lurking
                self.lurkCycle += 1
                self.lurkHidden = false
                self.scheduleLurk()
            }
        }
    }

    /// Waits out one lurking loop, then picks what Clawd does next while he's out of sight.
    private func scheduleLurk() {
        lurkWork = after(Clawd.sprite("lurking")?.duration ?? 5.6) { [weak self] in self?.nextLurk() }
    }

    /// Keep lurking, walk behind the notch to the other side (hidden for a second), or come out to dance or wave.
    private func nextLurk() {
        lurksSinceAct += 1
        let roll = Double.random(in: 0..<1)
        if roll < 0.24 && lurksSinceAct >= minLurks {
            comeOut(roll < 0.12 ? .dancing : .waving)
        } else if roll < 0.54 || (lurkSide == .right && !fitsRightOfNotch(.lurking)) {
            if lurkSide == .left && !fitsRightOfNotch(.lurking) {
                lurkCycle += 1
                scheduleLurk()
                return
            }
            lurkHidden = true
            lurkWork = after(1) { [weak self] in
                guard let self else { return }
                self.lurkSide = self.lurkSide == .left ? .right : .left
                self.lurkCycle += 1
                self.lurkHidden = false
                self.scheduleLurk()
            }
        } else {
            lurkCycle += 1
            scheduleLurk()
        }
    }

    // MARK: - Geometry

    private func layout() {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = screen.frame
        var g = NotchGeometry(screenFrame: frame, notchWidth: 180, notchHeight: max(24, frame.maxY - screen.visibleFrame.maxY), notchMidX: frame.midX)
        if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            g.notchWidth = frame.width - left.width - right.width
            g.notchHeight = screen.safeAreaInsets.top
            g.notchMidX = frame.minX + left.width + g.notchWidth / 2
        }
        geometry = g
        let size = IslandLayout.panelSize
        panel.setFrame(NSRect(x: g.notchMidX - size.width / 2, y: frame.maxY - size.height, width: size.width, height: size.height), display: true)
    }

    /// Height of the session list (plus the 1pt divider above it), matching its sections.
    var listHeight: CGFloat {
        let g = groups
        guard !g.isEmpty else { return IslandLayout.emptyHeight }
        let working = g.working.count
        let done = g.done.count
        let recent = g.recent.count
        func section(_ count: Int, row: CGFloat, gap: CGFloat) -> CGFloat {
            guard count > 0 else { return 0 }
            let rows = CGFloat((count + 1) / 2)
            return IslandLayout.sectionLabel + IslandLayout.sectionLabelGap + rows * row + (rows - 1) * gap
        }
        let extra = settings.showSessionDetails ? IslandLayout.detailsLine : 0
        let card = IslandLayout.cardHeight + extra, row = IslandLayout.rowHeight + extra
        let total = section(working, row: card, gap: IslandLayout.cardGap)
            + section(done, row: row, gap: IslandLayout.rowGap)
            + section(recent, row: row, gap: IslandLayout.rowGap)
            + section(g.idle.count, row: row, gap: IslandLayout.rowGap)
            + IslandLayout.listBottom + 1
        return min(total, IslandLayout.maxListHeight)
    }

    /// The meters, plus the "Last checked" line when the latest check failed; nothing when they're turned off.
    var usageHeight: CGFloat {
        settings.showUsage ? IslandLayout.usageHeight + (usage.isStale ? IslandLayout.staleLine : 0) : 0
    }

    /// Everything between the header and the footer on the sessions page.
    private var sessionsPageHeight: CGFloat {
        let banner = sessions.terminalProblem == nil ? 0 : IslandLayout.bannerHeight
        let noteLine = note == nil ? 0 : IslandLayout.noteHeight
        let search = query.isEmpty ? 0 : IslandLayout.searchHeight
        return usageHeight + banner + search + listHeight + noteLine
    }

    var settingsPageHeight: CGFloat { IslandLayout.settingsHeight }

    var islandSize: CGSize {
        switch mode {
        case .collapsed:
            // Just the notch; Clawd lurks outside the black shape, on the bare menu bar.
            return CGSize(width: geometry.notchWidth + IslandLayout.ear * 2, height: geometry.notchHeight)
        case .expanded:
            return CGSize(width: IslandLayout.expandedWidth,
                          height: geometry.notchHeight + (showingSettings ? settingsPageHeight : sessionsPageHeight) + IslandLayout.footerHeight)
        case .toast, .working:
            return CGSize(width: IslandLayout.toastWidth, height: geometry.notchHeight + IslandLayout.toastBody)
        }
    }

    /// The island's rect in screen coordinates.
    var islandRect: NSRect {
        let size = islandSize
        return NSRect(x: geometry.notchMidX - size.width / 2, y: geometry.screenFrame.maxY - size.height,
                      width: size.width, height: size.height)
    }

    private var hoverZone: NSRect {
        let left = geometry.notchMidX - geometry.notchWidth / 2 - IslandLayout.clawdWing - 8
        let right = geometry.notchMidX + geometry.notchWidth / 2 + IslandLayout.clawdWing + 8
        return NSRect(x: left, y: geometry.screenFrame.maxY - geometry.notchHeight - 2, width: right - left, height: geometry.notchHeight + 6)
    }

    // MARK: - Hover

    private func handleMouse() {
        guard panel != nil else { return }
        let p = NSEvent.mouseLocation
        if pinned {
            panel.ignoresMouseEvents = false
            updateHover(at: p, interactive: islandRect.contains(p))
            return
        }
        switch mode {
        case .collapsed, .toast:
            if hoverZone.contains(p) {
                if hoverWork == nil { hoverWork = after(0.08) { [weak self] in self?.expand() } }
            } else {
                hoverWork?.cancel()
                hoverWork = nil
            }
            if case .toast = mode {
                let inside = islandRect.contains(p)
                if inside { toastWork?.cancel(); toastWork = nil } else if hoveringToast { scheduleToastDismiss(after: 2) }
                hoveringToast = inside
            }
        case .expanded:
            if islandRect.contains(p) { holdHeight = 0 }
            var keepOpen = islandRect
            if holdHeight > keepOpen.height { keepOpen = NSRect(x: keepOpen.minX, y: keepOpen.maxY - holdHeight, width: keepOpen.width, height: holdHeight) }
            if keepOpen.insetBy(dx: -2, dy: -2).contains(p) {
                collapseWork?.cancel()
                collapseWork = nil
            } else if collapseWork == nil {
                collapseWork = after(0.3) { [weak self] in self?.collapse() }
            }
        case .working:
            break
        }
        let interactive: Bool
        switch mode {
        case .expanded, .toast: interactive = islandRect.contains(p)
        default: interactive = false
        }
        if panel.ignoresMouseEvents == interactive { panel.ignoresMouseEvents = !interactive }
        updateHover(at: p, interactive: interactive)
    }

    /// Highlights whatever clickable thing is under the pointer, straight from the mouse position.
    private func updateHover(at p: NSPoint, interactive: Bool) {
        var hit: String?
        if interactive {
            let local = CGPoint(x: p.x - panel.frame.minX, y: panel.frame.maxY - p.y)
            let list = hoverFrames["list"]
            hit = hoverFrames.first { id, frame in
                id != "list" && frame.contains(local) && (!id.hasPrefix("cell-") || list?.contains(local) == true)
            }?.key
        }
        if hit != nil {
            NSCursor.pointingHand.set()
        } else if hovered != nil {
            NSCursor.arrow.set()
        }
        if hit != hovered { hovered = hit }
    }

    func expand() {
        hoverWork = nil
        guard mode != .expanded, !working else { return }
        toastWork?.cancel()
        sessions.fastTerminalRefresh = true
        sessions.refreshTerminal()
        sessions.refreshDetails()
        usage.refreshIfStale()
        mode = .expanded
        panel.takesKeyboard = true
        panel.makeKeyAndOrderFront(nil)
        handleMouse()
    }

    func collapse() {
        collapseWork = nil
        guard !pinned, !working else { return }
        // A pointing hand set over a row would otherwise outlive the row.
        if islandRect.contains(NSEvent.mouseLocation) { NSCursor.arrow.set() }
        if mode == .expanded { waving.removeAll() }
        hovered = nil
        confirmingMove = false
        // Opening the island again always starts on the sessions, not settings.
        showingSettings = false
        holdHeight = 0
        query = ""
        selectedPid = nil
        sessions.fastTerminalRefresh = false
        mode = .collapsed
        panel.ignoresMouseEvents = true
        releaseKeyboard()
        updater?.islandClosed()
    }

    /// Hands typing back to the app in front (the terminal). The app never activated, so taking the
    /// panel off screen for an instant is enough for the window server to move the keyboard back.
    /// That would cut the closing animation short, so it waits for the island to finish closing.
    private func releaseKeyboard() {
        panel.takesKeyboard = false
        after(0.45) { [weak self] in
            guard let self, self.mode == .collapsed, self.panel.isKeyWindow else { return }
            self.panel.orderOut(nil)
            self.panel.orderFrontRegardless()
        }
    }

    private func celebrate() {
        celebrating = true
        after(3.4) { [weak self] in self?.celebrating = false }
    }

    /// A one-line result above the buttons; it clears itself.
    private func show(note text: String) {
        note = text
        noteWork?.cancel()
        noteWork = after(6) { [weak self] in self?.note = nil }
    }

    @discardableResult
    private func after(_ seconds: TimeInterval, _ work: @escaping () -> Void) -> DispatchWorkItem {
        let item = DispatchWorkItem(block: work)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
        return item
    }

    // MARK: - Search

    struct SessionGroups {
        var working: [ClaudeSession] = []
        var done: [ClaudeSession] = []
        var recent: [ClaudeSession] = []
        var idle: [ClaudeSession] = []
        /// In the order they're shown.
        var all: [ClaudeSession] { working + done + recent + idle }
        var isEmpty: Bool { working.isEmpty && done.isEmpty && recent.isEmpty && idle.isEmpty }
    }

    /// The island's sections, narrowed to the search.
    var groups: SessionGroups {
        let terms = query.split(separator: " ").map(String.init)
        let list = sessions.sessions.filter { s in terms.allSatisfy { s.name.localizedStandardContains($0) || s.folder.localizedStandardContains($0) } }
        return SessionGroups(
            working: list.filter(\.isActive),
            done: list.filter { $0.state == .finished }.sorted { $0.since > $1.since },
            recent: list.filter(\.recent).sorted { $0.since > $1.since },
            idle: list.filter { $0.state == .idle && !$0.recent })
    }

    /// Typing with the island open searches; Enter opens the selected session, arrows move the
    /// selection (two columns: left/right by one, up/down by a row), Esc clears, then closes.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard mode == .expanded, !confirmingMove else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if showingSettings {
            // No search on the settings page: Esc goes back to the sessions, ⌘ shortcuts work as usual.
            if event.keyCode == 53 { showingSettings = false }
            return !flags.contains(.command) || event.keyCode == 53
        }
        switch event.keyCode {
        case 53:   // Esc
            if query.isEmpty { collapse() } else { setQuery("") }
        case 36, 76:   // Return, Enter
            if let pid = selectedPid ?? groups.all.first?.pid { focus(pid) }
        case 51:   // Delete
            if flags.contains(.command) {
                setQuery("")
            } else if flags.contains(.option) {
                setQuery(String(query.trimmingCharacters(in: .whitespaces).reversed().drop { $0 != " " }.reversed()))
            } else if !query.isEmpty {
                setQuery(String(query.dropLast()))
            }
        case 123: moveSelection(by: -1)   // left
        case 124: moveSelection(by: 1)    // right
        case 125: moveSelection(by: 2)    // down
        case 126: moveSelection(by: -2)   // up
        case 48: moveSelection(by: flags.contains(.shift) ? -1 : 1)   // Tab
        default:
            if flags.contains(.command) {
                guard event.charactersIgnoringModifiers == "v" else { return false }   // ⌘Q, ⌘W etc. as usual
                let pasted = NSPasteboard.general.string(forType: .string)?.components(separatedBy: .newlines).first ?? ""
                setQuery(query + pasted)
            } else if !flags.contains(.control), let text = event.characters,
                      !text.isEmpty, text.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F && !(0xF700...0xF8FF).contains($0.value) }) {
                setQuery(query + text)
            }
        }
        // Swallow everything else too, so nothing beeps.
        return true
    }

    private func setQuery(_ text: String) {
        query = text
        selectedPid = text.isEmpty ? nil : groups.all.first?.pid
    }

    private func moveSelection(by step: Int) {
        let all = groups.all
        guard !all.isEmpty else { return }
        guard let current = selectedPid, let i = all.firstIndex(where: { $0.pid == current }) else {
            selectedPid = all.first?.pid
            return
        }
        selectedPid = all[min(max(i + step, 0), all.count - 1)].pid
    }

    // MARK: - Events

    private func present(_ event: SessionEvent) {
        if case .finished = event.kind { waving.insert(event.pid) }
        if settings.playSound {
            if case .finished = event.kind { NSSound(named: "Glass")?.play() } else { NSSound(named: "Funk")?.play() }
        }
        guard settings.popUpOnEvents else { return }
        switch mode {
        case .expanded, .working: return
        default: break
        }
        mode = .toast(event)
        hoveringToast = false
        scheduleToastDismiss(after: 6)
    }

    private func scheduleToastDismiss(after seconds: TimeInterval) {
        toastWork?.cancel()
        toastWork = after(seconds) { [weak self] in
            guard let self, case .toast = self.mode else { return }
            self.collapse()
        }
    }

    func focus(_ pid: Int32) {
        guard let session = sessions.sessions.first(where: { $0.pid == pid }) else { return }
        waving.remove(pid)
        sessions.markSeen(pid)
        collapse()
        if case .toast = mode { mode = .collapsed }
        DispatchQueue.global(qos: .userInitiated).async {
            if let window = session.windowID {
                try? TerminalBridge.focus(windowID: window, tab: session.tabIndex)
            } else if let tmux = session.tmuxSession {
                // Not in any window right now: open one on this desktop.
                try? TerminalBridge.openWindow(running: Tmux.attachCommand(tmux))
            }
        }
    }

    func newChat() {
        let screens = ScreenInfo.all()
        let capacity = settings.windowsPerDesktop
        collapse()
        comeOut(.racing)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try Reorganizer.openNewChat(screens: screens, capacity: capacity)
            } catch {
                DispatchQueue.main.async { self.show(note: "Couldn't open a new chat: \(error.localizedDescription)") }
            }
        }
    }

    // MARK: - Reorganise

    /// Sessions started before the tmux setup that can be moved into it now.
    var movableSessions: [ClaudeSession] {
        sessions.sessions.filter { !$0.inTmux && $0.onScreen && ($0.state == .idle || $0.state == .finished) }
    }

    /// Instant: points each Terminal window at a different tmux session. Nothing moves on screen.
    func reorganise() {
        let list = sessions.sessions
        let screens = ScreenInfo.all()
        let opensWindows = settings.reorganiseOpensWindows
        let capacity = settings.windowsPerDesktop
        show(note: "Reorganising…")
        DispatchQueue.global(qos: .userInitiated).async {
            var message: String
            var switched = 0
            do {
                let spread = try Reorganizer.spreadOut(screens: screens, capacity: capacity, openMissing: opensWindows)
                let paired = try Reorganizer.pairUp(screens: screens, capacity: capacity)
                (message, switched) = try Reorganizer.execute(Reorganizer.plan(sessions: list, screens: screens, capacity: capacity))
                if paired > 0 { message = "Paired up \(paired) window\(paired == 1 ? "" : "s") · " + message }
                if spread.opened > 0 { message = "Opened \(spread.opened) window\(spread.opened == 1 ? "" : "s") · " + message }
                if let note = spread.note { message += " · " + note }
            } catch {
                message = error.localizedDescription
            }
            DispatchQueue.main.async {
                self.show(note: message)
                self.sessions.refreshTerminal()
                if switched > 0 { self.celebrate() }
            }
        }
    }

    /// Restarts idle sessions that predate the tmux setup inside tmux, one by one, in their own windows.
    func moveIntoTmux() {
        confirmingMove = false
        let targets = movableSessions
        guard !targets.isEmpty, !working else { return }
        working = true
        mode = .working("1 of \(targets.count)", done: false)
        panel.ignoresMouseEvents = true
        DispatchQueue.global(qos: .userInitiated).async {
            var failed: [String] = []
            for (i, session) in targets.enumerated() {
                DispatchQueue.main.async { self.mode = .working("\(i + 1) of \(targets.count) · \(session.name)", done: false) }
                do { try Migration.moveIntoTmux(session) } catch { failed.append(error.localizedDescription) }
            }
            let moved = targets.count - failed.count
            let message = (["Moved \(moved) session\(moved == 1 ? "" : "s") into tmux"] + failed).joined(separator: " · ")
            DispatchQueue.main.async {
                self.working = false
                self.show(note: message)
                self.mode = .working(message, done: failed.isEmpty)
                self.after(3) { [weak self] in
                    self?.sessions.refreshTerminal()
                    guard let self, case .working = self.mode else { return }
                    self.collapse()
                }
            }
        }
    }
}
