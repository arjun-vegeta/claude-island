import Darwin
import Foundation

/// Claude Island's own tmux server (socket "claude-island"). Each Claude Code session lives in its own
/// tmux session; each Terminal window is a tmux client showing one of them. Reorganising is just
/// switching which session each client shows.
enum Tmux {
    static let socket = "claude-island"

    /// Homebrew's tmux when there is one (so it matches a server it already started), otherwise the copy
    /// the app ships with.
    static let binary: String? = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux",
                                  ShellSupport.home.appendingPathComponent("bin/tmux").path, "/usr/bin/tmux"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    /// The launcher script that starts claude inside this server (installed from the app, see ShellSupport).
    static let launcher = ShellSupport.home.appendingPathComponent("claude-tmux").path

    struct Pane {
        let tty: String
        let session: String
        let title: String
    }

    struct Client {
        /// The Terminal tab it's in.
        let tty: String
        /// tmux's own name for it (for switch-client). The same as `tty` unless it runs behind the relay.
        let tmuxTTY: String
        let session: String
    }

    /// Sits between a Terminal window and tmux so dragged-in screenshots work (shell/relay.c).
    static let relay = ShellSupport.home.appendingPathComponent("relay/tmux").path

    /// nil when tmux is missing or the server isn't running.
    @discardableResult
    static func run(_ args: [String]) -> String? {
        guard let binary else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["-L", socket] + args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }

    static func panes() -> [Pane] {
        rows(["list-panes", "-a", "-F", "#{pane_tty}\t#{session_name}\t#{pane_title}"]).compactMap { f in
            f.count >= 3 ? Pane(tty: f[0], session: f[1], title: f[2...].joined(separator: "\t")) : nil
        }
    }

    static func clients() -> [Client] {
        rows(["list-clients", "-F", "#{client_tty}\t#{session_name}\t#{client_pid}"]).compactMap { f in
            guard f.count >= 3 else { return nil }
            // Behind the relay, the client's tty is the relay's pty; the Terminal tab is the relay's tty.
            // Either way that's the tty of the client's parent (the relay, or the tab's shell).
            let tab = Int32(f[2]).flatMap(parentTTY) ?? f[0]
            return Client(tty: tab, tmuxTTY: f[0], session: f[1])
        }
    }

    /// The controlling terminal of `pid`'s parent, as "/dev/ttys005".
    private static func parentTTY(of pid: Int32) -> String? {
        func info(_ pid: Int32) -> kinfo_proc? {
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            var proc = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            guard sysctl(&mib, 4, &proc, &size, nil, 0) == 0, size > 0 else { return nil }
            return proc
        }
        guard let child = info(pid), let parent = info(child.kp_eproc.e_ppid) else { return nil }
        let dev = parent.kp_eproc.e_tdev
        guard dev != -1, let name = devname(dev, S_IFCHR) else { return nil }
        return "/dev/" + String(cString: name)
    }

    /// Every session on the server, oldest first.
    static func sessionNames() -> [String] {
        rows(["list-sessions", "-F", "#{session_created}\t#{session_name}"])
            .filter { $0.count >= 2 }
            .sorted { (Int($0[0]) ?? 0) < (Int($1[0]) ?? 0) }
            .map { $0[1] }
    }

    /// Points each client at its new session, all in one tmux call.
    static func switchClients(_ moves: [(clientTTY: String, session: String)]) -> Bool {
        guard !moves.isEmpty else { return true }
        var args: [String] = []
        for (i, move) in moves.enumerated() {
            if i > 0 { args.append(";") }
            args += ["switch-client", "-c", move.clientTTY, "-t", "=\(move.session)"]
        }
        return run(args) != nil
    }

    /// Shell command that shows `session` in a Terminal window.
    static func attachCommand(_ session: String) -> String {
        let relayed = FileManager.default.isExecutableFile(atPath: relay) ? shellQuote(relay) + " " : ""
        return "\(relayed)\(binary ?? "tmux") -L \(socket) attach -t \(shellQuote("=" + session))"
    }

    private static func rows(_ args: [String]) -> [[String]] {
        (run(args) ?? "").split(separator: "\n").map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
    }
}

func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
