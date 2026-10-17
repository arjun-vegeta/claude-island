import AppKit

if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "--cli" {
    CLI.run(Array(CommandLine.arguments.dropFirst(2)))
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
