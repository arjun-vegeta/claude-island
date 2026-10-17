import Foundation

/// A chat's model, effort and how full its context is, as Claude Code recorded them with its latest
/// reply. Claude Code writes each reply to the chat's transcript with the model that answered, the
/// effort it ran at, and the reply's token usage; nothing else reports these for a running chat.
struct SessionDetails: Equatable {
    /// "Opus 5.5"
    let model: String
    /// "high", "xhigh"; nil when the model doesn't take an effort level.
    let effort: String?
    /// Tokens in the context window as of the latest reply; nil right after /compact.
    let contextTokens: Int?
    /// The model's context window: 1M for current models, 200k for older ones.
    let window: Int

    /// "Opus 5.5 · high · 38% of 1M"
    var text: String {
        var parts = [model]
        if let effort { parts.append(effort) }
        if let contextTokens {
            let percent = Int((Double(contextTokens) / Double(window) * 100).rounded())
            parts.append("\(percent)% of \(Self.tokens(window))")
        }
        return parts.joined(separator: " · ")
    }

    /// 1000000 → "1M", 200000 → "200k".
    static func tokens(_ n: Int) -> String {
        if n >= 1_000_000, n % 1_000_000 == 0 { return "\(n / 1_000_000)M" }
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        return "\(Int((Double(n) / 1000).rounded()))k"
    }
}

/// Reads details from the end of a chat's transcript (~/.claude/projects/<folder>/<session id>.jsonl).
/// Transcripts grow to many megabytes, so only the tail is read, and only when the file has changed.
final class TranscriptReader {
    private struct Cached {
        let size: UInt64
        let modified: Date
        let details: SessionDetails?
    }

    /// CLAUDE_ISLAND_PROJECTS_DIR points it at a test folder instead (scripts/demo.sh).
    private let projects = ProcessInfo.processInfo.environment["CLAUDE_ISLAND_PROJECTS_DIR"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    private var paths: [String: URL] = [:]
    private var cache: [String: Cached] = [:]

    /// Blocking file reads: call off the main thread.
    func details(sessionId: String, cwd: String) -> SessionDetails? {
        guard let url = path(sessionId: sessionId, cwd: cwd),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = attributes[.modificationDate] as? Date ?? .distantPast
        if let hit = cache[sessionId], hit.size == size, hit.modified == modified { return hit.details }
        let details = read(url, size: size)
        cache[sessionId] = Cached(size: size, modified: modified, details: details)
        return details
    }

    /// Forgets chats that have ended.
    func keep(_ sessionIds: Set<String>) {
        cache = cache.filter { sessionIds.contains($0.key) }
        paths = paths.filter { sessionIds.contains($0.key) }
    }

    private func path(sessionId: String, cwd: String) -> URL? {
        if let known = paths[sessionId], FileManager.default.fileExists(atPath: known.path) { return known }
        // Claude Code names the folder after the working directory, every other character turned into "-".
        let folder = String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        var url = projects.appendingPathComponent(folder).appendingPathComponent(sessionId + ".jsonl")
        if !FileManager.default.fileExists(atPath: url.path) {
            // Moved with /cd, or a long path Claude Code shortened: look in every project folder.
            let folders = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
            guard let found = folders.map({ $0.appendingPathComponent(sessionId + ".jsonl") })
                .first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return nil }
            url = found
        }
        paths[sessionId] = url
        return url
    }

    /// The latest reply of the chat itself (not a subagent's), from the last part of the file.
    private func read(_ url: URL, size: UInt64) -> SessionDetails? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        for tail in [UInt64(512 << 10), UInt64(4 << 20)] {
            let start = size > tail ? size - tail : 0
            try? handle.seek(toOffset: start)
            guard let data = try? handle.readToEnd() else { return nil }
            var compactedAfter = false
            for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
                // Cheap checks before parsing: most lines are tool output.
                if !compactedAfter, line.firstRange(of: Data("\"compact_boundary\"".utf8)) != nil,
                   let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                   entry["type"] as? String == "system", entry["subtype"] as? String == "compact_boundary" {
                    // The context was summarised after the latest reply; its size isn't known until the next one.
                    compactedAfter = true
                    continue
                }
                guard line.firstRange(of: Data("\"type\":\"assistant\"".utf8)) != nil,
                      let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      entry["isSidechain"] as? Bool != true,
                      let message = entry["message"] as? [String: Any],
                      let model = message["model"] as? String, model != "<synthetic>",
                      let usage = message["usage"] as? [String: Any] else { continue }
                var used = 0
                for key in ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"] {
                    used += (usage[key] as? NSNumber)?.intValue ?? 0
                }
                let requested = entry["requestedModel"] as? String ?? model
                let window = max(Self.window(model: requested), used > 200_000 ? 1_000_000 : 0)
                return SessionDetails(model: Self.displayName(model), effort: entry["effort"] as? String,
                                      contextTokens: compactedAfter ? nil : used, window: window)
            }
            if start == 0 { break }
        }
        return nil
    }

    /// "claude-opus-5-5" → "Opus 5.5", "claude-haiku-5-5-20261001" → "Haiku 5.5", "claude-3-5-sonnet-20241022" → "Sonnet 3.5".
    static func displayName(_ id: String) -> String {
        let pieces: [String] = id.replacingOccurrences(of: "[1m]", with: "").split(separator: "-").map(String.init)
        // Drop "claude" and a trailing date such as 20261001.
        let parts: [String] = pieces.filter { piece in
            let isDate = piece.count == 8 && Int(piece) != nil
            return piece != "claude" && !isDate
        }
        guard let family = parts.first(where: { $0.first?.isLetter == true }) else { return id }
        let version: String = parts.filter { Int($0) != nil }.joined(separator: ".")
        let name: String = family.prefix(1).uppercased() + String(family.dropFirst())
        return version.isEmpty ? name : "\(name) \(version)"
    }

    /// Context window by model, as Claude Code's docs give it: the [1m] variants and current models
    /// (Fable, Sonnet 5 and later, Haiku 5.5 and later, Opus 4.7 and later) have 1M; older ones 200k.
    static func window(model id: String) -> Int {
        if id.contains("[1m]") { return 1_000_000 }
        let parts: [String] = id.split(separator: "-").map(String.init)
        guard let family = parts.first(where: { $0.first?.isLetter == true && $0 != "claude" }) else { return 200_000 }
        let numbers: [Int] = parts.compactMap { $0.count < 8 ? Int($0) : nil }
        let major = Double(numbers.first ?? 0)
        let minor = Double(numbers.dropFirst().first ?? 0)
        let version: Double = major + minor / 10
        switch family {
        case "fable": return 1_000_000
        case "sonnet": return version >= 5 ? 1_000_000 : 200_000
        case "haiku": return version >= 5.5 ? 1_000_000 : 200_000
        case "opus": return version >= 4.7 ? 1_000_000 : 200_000
        default: return 200_000
        }
    }
}
