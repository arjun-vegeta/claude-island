import AppKit

/// One terminal in cmux (cmux calls it a surface; AppleScript calls it a terminal).
struct CmuxTerminal {
    /// The same id cmux puts in CMUX_SURFACE_ID for the shell it starts there.
    let id: String
    /// The workspace (cmux's "tab") holding it, and that workspace's title in the sidebar.
    let workspaceID: String
    let workspaceName: String
    /// How many terminals that workspace has; a lone terminal's workspace title is the chat's title.
    let workspaceTerminals: Int
    /// Focused in the selected workspace of cmux's front window: what you'd type into if cmux were frontmost.
    let inFront: Bool
}

/// Talks to cmux (com.cmuxterm.app) through its AppleScript dictionary. Its command-line socket
/// only accepts processes cmux started itself, so AppleScript is the way in from outside.
enum Cmux {
    static let bundleID = "com.cmuxterm.app"

    static var app: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    static let notAllowed = "Allow Claude Island to control cmux in System Settings › Privacy & Security › Automation."

    @discardableResult
    private static func run(_ source: String) throws -> String {
        do {
            return try TerminalBridge.run(source)
        } catch TerminalError.notAllowed {
            throw TerminalError.failed(notAllowed)
        }
    }

    /// Every terminal in every cmux window, in one round trip.
    static func listTerminals() throws -> [CmuxTerminal] {
        guard app != nil else { return [] }
        let script = """
        tell application id "\(bundleID)"
            set ft to ""
            try
                set ft to id of focused terminal of selected tab of front window
            end try
            set tids to id of every tab of every window
            set tnames to name of every tab of every window
            set xids to id of every terminal of every tab of every window
        end tell
        set US to character id 31
        set out to ""
        repeat with i from 1 to count of tids
            repeat with j from 1 to count of (item i of tids)
                set xs to item j of (item i of xids)
                repeat with x in xs
                    set out to out & (x as text) & US & (item j of (item i of tids)) & US & ((count of xs) as text) & US & (((x as text) is ft) as text) & US & (item j of (item i of tnames)) & linefeed
                end repeat
            end repeat
        end repeat
        return out
        """
        return try run(script).split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\u{1F}", omittingEmptySubsequences: false)
            guard f.count >= 5 else { return nil }
            return CmuxTerminal(id: String(f[0]), workspaceID: String(f[1]), workspaceName: f[4...].joined(separator: "\u{1F}"),
                                workspaceTerminals: Int(f[2]) ?? 1, inFront: f[3] == "true")
        }
    }

    /// Selects the terminal's workspace, focuses the terminal and brings cmux forward.
    static func focus(terminal id: String) throws {
        try run("""
        tell application id "\(bundleID)"
            focus terminal id "\(escape(id))"
            activate
        end tell
        """)
    }

    /// Opens a new workspace in cmux's front window (or a new window) and runs `command` in its shell,
    /// as if typed. Text sent the moment the workspace opens can be lost, so it waits a little first;
    /// pasted text doesn't run by itself, so Return is sent separately.
    static func newWorkspace(running command: String) throws {
        if app == nil {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                throw TerminalError.failed("cmux isn't installed.")
            }
            NSWorkspace.shared.open(url)
            let deadline = Date().addingTimeInterval(10)
            while app?.isFinishedLaunching != true, Date() < deadline { usleep(100_000) }
        }
        try run("""
        tell application id "\(bundleID)"
            activate
            if (count of windows) is 0 then
                set w to new window
                set t to selected tab of w
            else
                set t to new tab in front window
            end if
            set x to focused terminal of t
            delay 0.6
            input text "\(escape(command))" to x
            perform action "text:\\\\r" on x
        end tell
        """)
    }

    static var installed: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
