import Foundation

/// The shell side of Claude Island: the zsh hook that runs `claude` inside tmux, the launcher, tmux's
/// settings, the link opener, the screenshot relay and (in release builds) tmux itself. They ship in
/// the app and are copied to ~/.claude-island at launch, a fixed place the ~/.zshrc line can point
/// at even if the app moves.
enum ShellSupport {
    static let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude-island")
    static let hookScript = home.appendingPathComponent("claude-island.zsh")
    private static let zshrc = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zshrc")
    private static let hookLine = "[ -f ~/.claude-island/claude-island.zsh ] && source ~/.claude-island/claude-island.zsh"

    /// Copies the app's shell files to ~/.claude-island, replacing any that changed. Each file is
    /// swapped in with a rename, so windows already running the relay or tmux keep their copy.
    static func install() {
        guard let source = Bundle.main.resourceURL?.appendingPathComponent("shell"),
              let files = FileManager.default.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey]) else { return }
        for case let file as URL in files {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let data = try? Data(contentsOf: file) else { continue }
            let relative = String(file.path.dropFirst(source.path.count + 1))
            let target = home.appendingPathComponent(relative)
            if (try? Data(contentsOf: target)) == data { continue }
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let temporary = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).new")
            let mode = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.posixPermissions] as? NSNumber ?? 0o644
            guard (try? data.write(to: temporary)) != nil else { continue }
            try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: temporary.path)
            rename(temporary.path, target.path)
        }
    }

    /// Whether ~/.zshrc runs `claude` through Claude Island (any copy of the hook counts).
    static var isHooked: Bool {
        ((try? String(contentsOf: zshrc, encoding: .utf8)) ?? "").contains("claude-island.zsh")
    }

    /// Adds the hook to ~/.zshrc; new Terminal windows pick it up.
    static func hook() throws {
        guard !isHooked else { return }
        let existing = (try? String(contentsOf: zshrc, encoding: .utf8)) ?? ""
        let block = (existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n")
            + "\n# Claude Island: run claude inside tmux, so the island can arrange your chats\n\(hookLine)\n"
        if FileManager.default.fileExists(atPath: zshrc.path) {
            let handle = try FileHandle(forWritingTo: zshrc)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(block.utf8))
        } else {
            try block.write(to: zshrc, atomically: true, encoding: .utf8)
        }
    }
}
