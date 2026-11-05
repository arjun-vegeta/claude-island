import AppKit
import Darwin

enum SessionStatus: String {
    case busy, waiting, idle
}

/// One live Claude Code session, as the claude binary describes itself in ~/.claude/sessions/<pid>.json.
struct RegistryEntry {
    let pid: Int32
    let sessionId: String
    let cwd: String
    let name: String
    let nameIsUser: Bool
    let status: SessionStatus
    let waitingFor: String?
    let statusSince: Date
    let tty: String?
    /// When the claude process started.
    let started: Date
    /// The cmux terminal it runs in (CMUX_SURFACE_ID), when cmux started its shell.
    let cmuxSurface: String?
}

enum Registry {
    /// CLAUDE_ISLAND_SESSIONS_DIR points it at a test folder instead.
    static let directory = ProcessInfo.processInfo.environment["CLAUDE_ISLAND_SESSIONS_DIR"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")

    /// procStart is written like "Tue Oct 13 08:21:23 2026", in UTC.
    private static let procStartFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return f
    }()

    static func liveSessions() -> [RegistryEntry] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        var entries: [RegistryEntry] = []
        for name in names where name.hasSuffix(".json") {
            guard let pid = Int32(name.dropLast(5)),
                  let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (obj["kind"] as? String ?? "interactive") == "interactive",
                  let proc = processInfo(pid) else { continue }

            // A stale file whose pid was reused by another process has a different start time.
            let started = processStart(proc)
            if let start = obj["procStart"] as? String,
               let date = procStartFormat.date(from: start.split(separator: " ").joined(separator: " ")),
               abs(started.timeIntervalSince(date)) > 5 { continue }

            let millis = { (key: String) in (obj[key] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) } }
            entries.append(RegistryEntry(
                pid: pid,
                sessionId: obj["sessionId"] as? String ?? "",
                cwd: obj["cwd"] as? String ?? "",
                name: obj["name"] as? String ?? "",
                nameIsUser: (obj["nameSource"] as? String) == "user",
                status: SessionStatus(rawValue: obj["status"] as? String ?? "") ?? .idle,
                waitingFor: obj["waitingFor"] as? String,
                statusSince: millis("statusUpdatedAt") ?? millis("updatedAt") ?? Date(),
                tty: terminal(of: proc),
                started: started,
                cmuxSurface: cmuxSurface(pid, started: started)
            ))
        }
        cmuxSurfaces = cmuxSurfaces.filter { key, _ in entries.contains { $0.pid == key.pid } }
        return entries
    }

    private struct ProcessKey: Hashable {
        let pid: pid_t
        let started: Date
    }

    /// A process's environment and parents never change, so each is looked up once.
    private static var cmuxSurfaces: [ProcessKey: String?] = [:]

    /// The cmux terminal a claude process runs in: CMUX_SURFACE_ID from its environment, when cmux
    /// is one of its parents. (A shell started elsewhere, a tmux server say, could have inherited it.)
    private static func cmuxSurface(_ pid: pid_t, started: Date) -> String? {
        let key = ProcessKey(pid: pid, started: started)
        if let cached = cmuxSurfaces[key] { return cached }
        let cmuxPids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: Cmux.bundleID).map(\.processIdentifier))
        var surface: String?
        if !cmuxPids.isEmpty, let id = environment(of: pid, key: "CMUX_SURFACE_ID"), !id.isEmpty {
            var parent = processInfo(pid)?.kp_eproc.e_ppid ?? 0
            for _ in 0..<16 where parent > 1 {
                if cmuxPids.contains(parent) { surface = id; break }
                parent = processInfo(parent)?.kp_eproc.e_ppid ?? 0
            }
        }
        // Not cached while cmux isn't running: its chats are gone then, and a pid could come back.
        if !cmuxPids.isEmpty { cmuxSurfaces[key] = .some(surface) }
        return surface
    }

    /// One variable from another process's environment (KERN_PROCARGS2: argc, the executable path,
    /// the arguments, then the environment, each NUL-terminated). Works for the user's own processes.
    private static func environment(of pid: pid_t, key: String) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return nil }
        let argc = buffer.withUnsafeBytes { Int($0.load(as: Int32.self)) }
        var i = 4
        func skipString() { while i < size, buffer[i] != 0 { i += 1 } }
        skipString()                                      // executable path
        while i < size, buffer[i] == 0 { i += 1 }         // its padding
        for _ in 0..<argc { skipString(); i += 1 }        // arguments
        let prefix = Array((key + "=").utf8)
        while i < size, buffer[i] != 0 {
            let start = i
            skipString()
            if i - start >= prefix.count, Array(buffer[start..<start + prefix.count]) == prefix {
                return String(decoding: buffer[(start + prefix.count)..<i], as: UTF8.self)
            }
            i += 1
        }
        return nil
    }

    private static func processInfo(_ pid: pid_t) -> kinfo_proc? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }

    private static func processStart(_ info: kinfo_proc) -> Date {
        let tv = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
    }

    /// devname() scans /dev on every call, which adds up when polled every second; a device's name never changes.
    private static var ttyNames: [dev_t: String?] = [:]

    private static func terminal(of info: kinfo_proc) -> String? {
        let dev = info.kp_eproc.e_tdev
        guard dev != -1 else { return nil }
        if let cached = ttyNames[dev] { return cached }
        let tty = devname(dev, S_IFCHR).map { String(cString: $0) }
        let path = tty.flatMap { $0.hasPrefix("?") ? nil : "/dev/" + $0 }
        ttyNames[dev] = path
        return path
    }
}
