import Foundation
import Network

struct UsageWindow: Identifiable, Equatable, Codable {
    let id: String
    let label: String
    let percent: Double
    let resetsAt: Date?
}

struct UsageSnapshot: Equatable, Codable {
    let windows: [UsageWindow]
    let extraUsed: Double?
    let extraLimit: Double?
    let currency: String
    let plan: String?
    let fetchedAt: Date
}

/// Plan usage straight from the claude binary: it is started in SDK mode and asked for the same
/// data /usage shows (`get_usage` control request). No prompt is sent, so no tokens are spent.
/// Offline, it keeps showing the last numbers it got (remembered across restarts), says how old they
/// are, and checks again as soon as the Mac is back online.
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var error: String?
    @Published private(set) var loading = false
    @Published private(set) var offline = false
    private var timer: Timer?
    private let network = NWPathMonitor()

    private static let saved = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude Island/usage.json")

    /// The numbers shown are from an earlier check, because the latest one failed.
    var isStale: Bool { snapshot != nil && (error != nil || offline) }

    /// For screen recordings (scripts/demo.sh): CLAUDE_ISLAND_DEMO_USAGE="54,78,31" shows those
    /// percentages, with the labels of the last real check, and never asks claude.
    private static let demoPercents: [Double]? = ProcessInfo.processInfo.environment["CLAUDE_ISLAND_DEMO_USAGE"]
        .map { $0.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) } }

    private static func demoSnapshot(_ percents: [Double]) -> UsageSnapshot {
        let saved = (try? Data(contentsOf: saved)).flatMap { try? JSONDecoder().decode(UsageSnapshot.self, from: $0) }
        let labels = saved?.windows.map { ($0.id, $0.label) } ?? [("five_hour", "Session"), ("seven_day", "Week"), ("model", "Week · Opus")]
        let resets: [TimeInterval] = [2 * 3600 + 13 * 60, 3 * 86400 + 5 * 3600, 3 * 86400 + 5 * 3600]
        let windows = zip(labels, percents).enumerated().map { i, pair in
            UsageWindow(id: pair.0.0, label: pair.0.1, percent: pair.1, resetsAt: Date().addingTimeInterval(resets[min(i, resets.count - 1)]))
        }
        return UsageSnapshot(windows: windows, extraUsed: nil, extraLimit: nil, currency: saved?.currency ?? "USD",
                             plan: saved?.plan, fetchedAt: Date())
    }

    func start() {
        if let percents = Self.demoPercents {
            snapshot = Self.demoSnapshot(percents)
            return
        }
        if let data = try? Data(contentsOf: Self.saved) { snapshot = try? JSONDecoder().decode(UsageSnapshot.self, from: data) }
        network.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self else { return }
                let wasOffline = self.offline
                self.offline = path.status != .satisfied
                if wasOffline && !self.offline { self.refresh() }
            }
        }
        network.start(queue: .global(qos: .utility))
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 180, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refreshIfStale(after age: TimeInterval = 60) {
        if let snapshot, Date().timeIntervalSince(snapshot.fetchedAt) < age { return }
        refresh()
    }

    func refresh() {
        if let percents = Self.demoPercents { snapshot = Self.demoSnapshot(percents); return }
        guard !loading else { return }
        loading = true
        DispatchQueue.global(qos: .utility).async {
            let result = UsageFetcher.fetch()
            DispatchQueue.main.async {
                self.loading = false
                switch result {
                case .success(let snapshot) where snapshot.windows.isEmpty && snapshot.extraLimit == nil:
                    // What claude answers when it can't reach Anthropic: keep the last numbers.
                    self.error = "claude couldn't reach Anthropic"
                case .success(let snapshot):
                    self.snapshot = snapshot
                    self.error = nil
                    try? JSONEncoder().encode(snapshot).write(to: Self.saved, options: .atomic)
                case .failure(let error):
                    self.error = error.localizedDescription
                }
            }
        }
    }
}

enum ClaudeBinary {
    static let path: String? = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.claude/local/claude"]
        if let hit = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return hit }
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-lc", "command -v claude"]
        let out = Pipe()
        shell.standardOutput = out
        shell.standardError = FileHandle.nullDevice
        guard (try? shell.run()) != nil else { return nil }
        let found = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        shell.waitUntilExit()
        return found.hasPrefix("/") ? found : nil
    }()
}

enum UsageFetcher {
    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    static func fetch(timeout: TimeInterval = 25) -> Result<UsageSnapshot, Error> {
        guard let binary = ClaudeBinary.path else { return .failure(Failure("Couldn't find the claude binary")) }

        let workDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Claude Island")
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        // Skip MCP servers, plugins and settings: this process only answers one control request.
        process.arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                             "--no-session-persistence", "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#,
                             "--setting-sources", ""]
        process.currentDirectoryURL = workDir
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\((binary as NSString).deletingLastPathComponent):/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:" + (env["PATH"] ?? "")
        process.environment = env
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do { try process.run() } catch { return .failure(error) }

        let lock = NSLock()
        var buffer = Data()
        var answer: [String: Any]?
        let done = DispatchSemaphore(value: 0)
        func send(_ object: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
            input.fileHandleForWriting.write(data + Data([0x0A]))
        }

        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            lock.lock()
            defer { lock.unlock() }
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                done.signal()
                return
            }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      obj["type"] as? String == "control_response",
                      let response = obj["response"] as? [String: Any] else { continue }
                switch response["request_id"] as? String {
                case "init":
                    send(["type": "control_request", "request_id": "usage", "request": ["subtype": "get_usage", "skip_behaviors": true]])
                case "usage":
                    answer = response
                    handle.readabilityHandler = nil
                    done.signal()
                default:
                    break
                }
            }
        }
        send(["type": "control_request", "request_id": "init", "request": ["subtype": "initialize"]])

        let timedOut = done.wait(timeout: .now() + timeout) == .timedOut
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }

        lock.lock()
        let response = answer
        lock.unlock()
        if timedOut { return .failure(Failure("claude didn't answer in time")) }
        guard let response else { return .failure(Failure("claude exited without an answer")) }
        if response["subtype"] as? String == "error" {
            return .failure(Failure(response["error"] as? String ?? "claude returned an error"))
        }
        guard let body = response["response"] as? [String: Any] else { return .failure(Failure("Unexpected answer from claude")) }
        return .success(parse(body))
    }

    static func parse(_ body: [String: Any]) -> UsageSnapshot {
        let limits = body["rate_limits"] as? [String: Any] ?? [:]
        var windows: [UsageWindow] = []
        func add(_ key: String, _ label: String, _ item: Any?) {
            guard let item = item as? [String: Any], let pct = (item["utilization"] as? NSNumber)?.doubleValue else { return }
            windows.append(UsageWindow(id: key, label: label, percent: pct, resetsAt: date(item["resets_at"] as? String)))
        }
        add("five_hour", "Session", limits["five_hour"])
        add("seven_day", "Week", limits["seven_day"])
        add("seven_day_opus", "Week · Opus", limits["seven_day_opus"])
        add("seven_day_sonnet", "Week · Sonnet", limits["seven_day_sonnet"])
        for item in limits["model_scoped"] as? [[String: Any]] ?? [] {
            let name = item["display_name"] as? String ?? "Model"
            add("model_\(name)", "Week · \(name)", item)
        }

        var extraUsed: Double?, extraLimit: Double?
        var currency = "USD"
        if let extra = limits["extra_usage"] as? [String: Any], extra["is_enabled"] as? Bool == true {
            let scale = pow(10, (extra["decimal_places"] as? NSNumber)?.doubleValue ?? 2)
            extraUsed = (extra["used_credits"] as? NSNumber).map { $0.doubleValue / scale }
            extraLimit = (extra["monthly_limit"] as? NSNumber).map { $0.doubleValue / scale }
            currency = extra["currency"] as? String ?? "USD"
        }
        return UsageSnapshot(windows: windows, extraUsed: extraUsed, extraLimit: extraLimit, currency: currency,
                             plan: body["subscription_type"] as? String, fetchedAt: Date())
    }

    private static func date(_ string: String?) -> Date? {
        guard let string else { return nil }
        // "2026-10-15T10:09:59.795811+00:00": drop the microseconds, which ISO8601DateFormatter rejects.
        let trimmed = string.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: trimmed)
    }
}
