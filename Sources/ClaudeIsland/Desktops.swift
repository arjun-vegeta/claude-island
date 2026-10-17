import AppKit

/// Moving between desktops (Spaces). macOS has no public way to switch to a desktop, and the private
/// "set current space" call leaves the screen unrepainted on recent macOS. What does work, with SIP on,
/// is pressing the "Move right/left a space" shortcut (Ctrl+→ / Ctrl+←, on by default): macOS accepts
/// it from a program when the key events come from the HID system state source and are posted at the
/// HID tap (see github.com/cehbz/spacekit). That needs the Accessibility permission. Each press is
/// checked against the window server, so a press that doesn't land stops everything.
enum Desktops {
    /// Whether Claude Island may press keys. With `ask`, macOS shows its permission prompt if not.
    static func canPressKeys(ask: Bool) -> Bool {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: ask] as CFDictionary)
    }

    /// Desktops holding at least one ordinary app window, so "empty" ones can be told apart. Window
    /// ids and their desktops are readable without Screen Recording; titles aren't needed.
    static func occupied() -> Set<UInt64> {
        let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var spaces = Set<UInt64>()
        for window in info {
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let id = window[kCGWindowNumber as String] as? Int,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  (bounds["Width"] as? Double ?? 0) > 120, (bounds["Height"] as? Double ?? 0) > 120 else { continue }
            let on = SkyLight.spaces(forWindow: CGWindowID(id))
            // A window shown on every desktop doesn't make any one of them busy.
            if on.count == 1 { spaces.insert(on[0]) }
        }
        return spaces
    }

    /// Goes to `target` on `display`. Jumps first to the nearest desktop with one of `windows` on it
    /// (bringing a Terminal window forward switches desktops reliably), then walks the rest with
    /// Ctrl+←/→. Returns false, and stops, as soon as macOS doesn't follow.
    static func go(to target: UInt64, on display: SkyLight.Display, windows: [(id: Int, space: UInt64)]) -> Bool {
        guard let goal = display.spaces.firstIndex(where: { $0.id == target }) else { return false }
        if SkyLight.activeSpace() == target { return true }

        func index(of space: UInt64) -> Int? { display.spaces.firstIndex { $0.id == space } }
        var here = index(of: SkyLight.activeSpace())
        let jump = windows.compactMap { w in index(of: w.space).map { (w.id, w.space, $0) } }
            .min { abs($0.2 - goal) < abs($1.2 - goal) }
        if let jump, here == nil || abs(jump.2 - goal) < abs(here! - goal) {
            try? TerminalBridge.focus(windowID: jump.0, tab: nil)
            guard wait(for: jump.1) else { return false }
            here = jump.2
        }
        guard var at = here else { return false }

        while at != goal {
            let step = goal > at ? 1 : -1
            pressControlArrow(right: step > 0)
            guard wait(for: display.spaces[at + step].id) else { return false }
            at += step
        }
        // Let the slide finish, so new windows open on this desktop rather than the one leaving.
        usleep(350_000)
        return true
    }

    private static func wait(for space: UInt64, timeout: TimeInterval = 2.5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while SkyLight.activeSpace() != space {
            if Date() > deadline { return false }
            usleep(40_000)
        }
        return true
    }

    private static func pressControlArrow(right: Bool) {
        let source = CGEventSource(stateID: .hidSystemState)
        let arrow: CGKeyCode = right ? 124 : 123
        let control: CGKeyCode = 59
        // Arrow keys carry the fn and keypad flags when typed on a real keyboard.
        let arrowFlags: CGEventFlags = [.maskControl, .maskSecondaryFn, .maskNumericPad]
        let events: [(CGKeyCode, Bool, CGEventFlags)] = [
            (control, true, .maskControl), (arrow, true, arrowFlags), (arrow, false, arrowFlags), (control, false, []),
        ]
        for (key, down, flags) in events {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
            usleep(12_000)
        }
    }
}
