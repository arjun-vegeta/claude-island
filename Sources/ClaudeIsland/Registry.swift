import Darwin
import Foundation

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
            if let start = obj["procStart"] as? String,
               let date = procStartFormat.date(from: start.split(separator: " ").joined(separator: " ")),
               abs(processStart(proc).timeIntervalSince(date)) > 5 { continue }

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
                tty: terminal(of: proc)
            ))
        }
        return entries
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
