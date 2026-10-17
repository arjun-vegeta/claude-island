import AppKit

/// Keeps Claude Island up to date from its GitHub releases. Once a day it asks GitHub for the latest
/// release; when it's newer than this copy, it downloads the same zip the install command uses,
/// swaps the app in place and restarts it. With automatic updates off it only says an update is there.
/// Restarting the app never touches your chats: they run in tmux, not in the app.
final class Updater: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(String)
        case installing(String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    /// "1.0.2"; nil for a build made with ./build.sh, which never updates itself.
    static let currentVersion: String? = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return version.flatMap { parse($0) == nil ? nil : $0 }
    }()

    private let latestURL = URL(string: "https://api.github.com/repos/arjun-vegeta/claude-island/releases/latest")!
    private let settings: Settings
    /// Whether restarting now would interrupt you (the island is open, or a Move into tmux is running).
    private let isBusy: () -> Bool
    private var download: URL?
    private var timer: Timer?
    private var lastCheck = Date.distantPast

    init(settings: Settings, isBusy: @escaping () -> Bool) {
        self.settings = settings
        self.isBusy = isBusy
    }

    var updateAvailable: Bool {
        if case .available = state { return true }
        return false
    }

    func start() {
        guard Self.currentVersion != nil else { return }
        // Shortly after launch, then hourly: check if a day has passed, and install a waiting update
        // once the island is closed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.tick() }
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func tick() {
        if case .available(let version) = state, settings.autoUpdate, !isBusy() {
            install(version)
        } else if Date().timeIntervalSince(lastCheck) > 24 * 60 * 60 {
            check()
        }
    }

    /// The island just closed: a waiting update installs now rather than at the next hourly tick.
    func islandClosed() {
        guard case .available(let version) = state, settings.autoUpdate else { return }
        // A moment later, so a quick move back to the notch doesn't land on a restarting app.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, !self.isBusy() else { return }
            self.install(version)
        }
    }

    /// Asks GitHub for the latest release.
    func check() {
        guard let current = Self.currentVersion else { return }
        if case .installing = state { return }
        lastCheck = Date()
        state = .checking
        var request = URLRequest(url: latestURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, _, error in
            let release = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let tag = (release?["tag_name"] as? String).map { $0.hasPrefix("v") ? String($0.dropFirst()) : $0 }
            let assets = release?["assets"] as? [[String: Any]] ?? []
            let zip = assets.first { $0["name"] as? String == "Claude-Island.zip" }?["browser_download_url"] as? String
            DispatchQueue.main.async {
                guard let tag, let zip, let url = URL(string: zip) else {
                    self.state = .failed(error == nil ? "Couldn't read the latest release" : "Couldn't reach GitHub")
                    return
                }
                guard Self.isNewer(tag, than: current) else { self.state = .upToDate; return }
                self.download = url
                self.state = .available(tag)
                if self.settings.autoUpdate, !self.isBusy() { self.install(tag) }
            }
        }.resume()
    }

    /// Downloads the release, checks it, swaps it in for this copy of the app and restarts.
    func install(_ version: String) {
        guard let download else { return }
        if case .installing = state { return }
        state = .installing(version)
        URLSession.shared.downloadTask(with: download) { file, _, error in
            let result = Result { () -> URL in
                guard let file else { throw UpdateError(error == nil ? "The download was empty" : "Couldn't download the update") }
                return try Self.replaceApp(with: file)
            }
            DispatchQueue.main.async {
                switch result {
                case .success(let app): Self.relaunch(app)
                case .failure(let error): self.state = .failed((error as? UpdateError)?.message ?? "The update failed")
                }
            }
        }.resume()
    }

    private struct UpdateError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    /// Unzips the download next to the app, checks it's Claude Island with an intact signature, and
    /// puts it where this copy is. Blocking: runs on the download's queue.
    private static func replaceApp(with zip: URL) throws -> URL {
        let current = Bundle.main.bundleURL
        let work = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                               appropriateFor: current, create: true)
        defer { try? FileManager.default.removeItem(at: work) }
        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path]) else { throw UpdateError("Couldn't unpack the update") }
        let fresh = work.appendingPathComponent("Claude Island.app")
        guard Bundle(url: fresh)?.bundleIdentifier == Bundle.main.bundleIdentifier,
              run("/usr/bin/codesign", ["--verify", "--deep", "--strict", fresh.path]) else {
            throw UpdateError("The update didn't check out, so it wasn't installed")
        }
        _ = try FileManager.default.replaceItemAt(current, withItemAt: fresh)
        return current
    }

    private static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// Opens the new copy a moment after this one quits (it refuses to run while another copy does).
    private static func relaunch(_ app: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", app.path]
        try? process.run()
        NSApp.terminate(nil)
    }

    /// "1.0.10" > "1.0.9".
    static func isNewer(_ a: String, than b: String) -> Bool {
        guard let x = parse(a), let y = parse(b) else { return false }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    private static func parse(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".").map { Int($0) }
        return parts.isEmpty || parts.contains(nil) ? nil : parts.compactMap { $0 }
    }
}
