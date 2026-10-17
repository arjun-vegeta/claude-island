import AppKit

struct TerminalTab {
    let tty: String
    let selected: Bool
    let title: String
}

struct TerminalWindow {
    /// Terminal's AppleScript window id, which is also the window server's CGWindowID.
    let id: Int
    /// 0 is the frontmost Terminal window.
    let zIndex: Int
    let miniaturized: Bool
    /// Global coordinates, top-left origin (AppleScript "bounds").
    let bounds: CGRect
    let tabs: [TerminalTab]
}

enum TerminalError: Error, CustomStringConvertible {
    case notAllowed
    case failed(String)

    var description: String {
        switch self {
        case .notAllowed: return "Allow Claude Island to control Terminal in System Settings › Privacy & Security › Automation."
        case .failed(let message): return message
        }
    }
}

/// Talks to Terminal.app through AppleScript (osascript), which is the only way to see each
/// window's tabs and ttys, including windows on other desktops.
enum TerminalBridge {
    static let bundleID = "com.apple.Terminal"

    static var app: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    @discardableResult
    static func run(_ source: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if message.contains("-1743") { throw TerminalError.notAllowed }
            throw TerminalError.failed(message.isEmpty ? "osascript failed" : message)
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func listWindows() throws -> [TerminalWindow] {
        guard app != nil else { return [] }
        let script = """
        tell application id "com.apple.Terminal"
            set wids to id of every window
            set minis to miniaturized of every window
            set bnds to bounds of every window
            set ttys to tty of every tab of every window
            set ttls to custom title of every tab of every window
            set sels to selected of every tab of every window
        end tell
        set US to character id 31
        set GS to character id 29
        set RS to character id 30
        set out to ""
        repeat with i from 1 to count of wids
            set b to item i of bnds
            set ln to ((item i of wids) as text) & US & ((item i of minis) as text) & US & ((item 1 of b) as text) & "," & ((item 2 of b) as text) & "," & ((item 3 of b) as text) & "," & ((item 4 of b) as text) & US
            set tt to item i of ttys
            repeat with j from 1 to count of tt
                set ln to ln & (item j of tt) & GS & ((item j of (item i of sels)) as text) & GS & (item j of (item i of ttls)) & RS
            end repeat
            set out to out & ln & linefeed
        end repeat
        return out
        """
        let output = try run(script)
        var windows: [TerminalWindow] = []
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\u{1F}", omittingEmptySubsequences: false)
            guard fields.count >= 4, let id = Int(fields[0]) else { continue }
            let b = fields[2].split(separator: ",").compactMap { Double($0) }
            guard b.count == 4 else { continue }
            let tabs = fields[3].split(separator: "\u{1E}").compactMap { tab -> TerminalTab? in
                let parts = tab.split(separator: "\u{1D}", omittingEmptySubsequences: false)
                guard parts.count >= 3 else { return nil }
                return TerminalTab(tty: String(parts[0]), selected: parts[1] == "true", title: String(parts[2...].joined(separator: "\u{1D}")))
            }
            windows.append(TerminalWindow(
                id: id,
                zIndex: windows.count,
                miniaturized: fields[1] == "true",
                bounds: CGRect(x: b[0], y: b[1], width: b[2] - b[0], height: b[3] - b[1]),
                tabs: tabs
            ))
        }
        return windows
    }

    /// Brings a window (and tab) forward; macOS switches to its desktop.
    static func focus(windowID: Int, tab: Int?) throws {
        let selectTab = tab.map { "set selected tab of w to tab \($0) of w" } ?? ""
        try run("""
        tell application id "com.apple.Terminal"
            set w to window id \(windowID)
            if miniaturized of w then set miniaturized of w to false
            \(selectTab)
            set index of w to 1
            activate
        end tell
        """)
    }

    /// Types a command into a tab's shell and runs it.
    static func type(_ command: String, windowID: Int, tab: Int) throws {
        try run("tell application id \"com.apple.Terminal\" to do script \"\(escape(command))\" in tab \(tab) of window id \(windowID)")
    }

    /// Opens a new Terminal window on the current desktop running `command` (one command, which
    /// replaces the window's script so Terminal sees only it running) in `directory`. Returns the new
    /// window's id.
    ///
    /// It opens the command as a .command file rather than with AppleScript's `do script`: macOS counts
    /// windows Terminal opens for a script as their own app, not Terminal, so files you drag in from
    /// the screenshot preview (which only Terminal may read) wouldn't reach Claude in them.
    @discardableResult
    static func openWindow(running command: String, in directory: String? = nil) throws -> Int? {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/claude-island-launch")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = UUID().uuidString
        let script = dir.appendingPathComponent(name + ".command")
        let ttyFile = dir.appendingPathComponent(name + ".tty")
        try """
        #!/bin/zsh
        rm -f "$0"
        tty > \(shellQuote(ttyFile.path))
        \(directory.map { "cd \(shellQuote($0)) || exit 1" } ?? "")
        exec \(command)
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)

        // In the background, so Terminal doesn't jump to a desktop with its other windows first.
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-g", "-b", bundleID, script.path]
        try open.run()
        open.waitUntilExit()

        // Found by the new tab's tty: "window 1" can be another window opened at the same moment.
        let deadline = Date().addingTimeInterval(8)
        var tty: String?
        while tty == nil, Date() < deadline {
            tty = (try? String(contentsOf: ttyFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            if tty == nil { usleep(50_000) }
        }
        try? FileManager.default.removeItem(at: ttyFile)
        guard let tty else { return nil }
        return Int(try run("""
        tell application id "com.apple.Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(escape(tty))" then
                        set index of w to 1
                        activate
                        return id of w
                    end if
                end repeat
            end repeat
        end tell
        """).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func close(windowID: Int) throws {
        try run("tell application id \"com.apple.Terminal\" to close window id \(windowID) saving no")
    }

    static func setBounds(_ items: [(windowID: Int, bounds: CGRect)]) throws {
        guard !items.isEmpty else { return }
        let lines = items.map { item -> String in
            let r = item.bounds.integral
            return "try\nset bounds of window id \(item.windowID) to {\(Int(r.minX)), \(Int(r.minY)), \(Int(r.maxX)), \(Int(r.maxY))}\nend try"
        }
        try run("tell application id \"com.apple.Terminal\"\n\(lines.joined(separator: "\n"))\nend tell")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
