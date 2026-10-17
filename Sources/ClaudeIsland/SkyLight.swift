import CoreGraphics
import Foundation

/// Read-only calls into the private SkyLight framework: the desktops (Spaces) on each display,
/// which desktop is showing, and which desktop a window lives on. Loaded with dlsym so a
/// missing symbol degrades to "unknown" instead of a crash.
enum SkyLight {
    private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    private static func load<T>(_ name: String, _: T.Type) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    private typealias MainConnectionFn = @convention(c) () -> Int32
    private typealias CopyManagedDisplaySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopySpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias GetActiveSpaceFn = @convention(c) (Int32) -> UInt64
    private typealias SetConnectionPropertyFn = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32

    private static let copyManagedDisplaySpaces = load("SLSCopyManagedDisplaySpaces", CopyManagedDisplaySpacesFn.self)
    private static let copySpacesForWindows = load("SLSCopySpacesForWindows", CopySpacesForWindowsFn.self)
    private static let getActiveSpace = load("SLSGetActiveSpace", GetActiveSpaceFn.self)
    private static let connection: Int32 = load("SLSMainConnectionID", MainConnectionFn.self)?() ?? 0

    struct Space: Equatable {
        let id: UInt64
        /// type 0 is a normal desktop; full-screen apps are type 4.
        let isDesktop: Bool
    }

    struct Display {
        let uuid: String
        /// Every space in Mission Control order, the order Ctrl+←/→ walks through.
        let spaces: [Space]
        let current: UInt64
        var desktops: [Space] { spaces.filter(\.isDesktop) }
    }

    static func displays() -> [Display] {
        guard let copy = copyManagedDisplaySpaces,
              let list = copy(connection)?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return list.map { display in
            let spaces = (display["Spaces"] as? [[String: Any]] ?? []).compactMap { space -> Space? in
                guard let id = (space["ManagedSpaceID"] as? NSNumber)?.uint64Value else { return nil }
                return Space(id: id, isDesktop: (space["type"] as? NSNumber)?.intValue == 0)
            }
            let current = ((display["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? NSNumber)?.uint64Value ?? 0
            return Display(uuid: display["Display Identifier"] as? String ?? "", spaces: spaces, current: current)
        }
    }

    static func spaces(forWindow id: CGWindowID) -> [UInt64] {
        guard let copy = copySpacesForWindows,
              let list = copy(connection, 0x7, [NSNumber(value: id)] as CFArray)?.takeRetainedValue() as? [NSNumber] else { return [] }
        return list.map(\.uint64Value)
    }

    /// Lets this app change the cursor while it isn't the active app (the island never activates,
    /// so it doesn't take focus from your terminal).
    static func allowCursorChangesInBackground() {
        guard let set = load("SLSSetConnectionProperty", SetConnectionPropertyFn.self) else { return }
        _ = set(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }

    static func activeSpace() -> UInt64 {
        getActiveSpace?(connection) ?? 0
    }

    /// Desktop number (1-based, as Mission Control labels them) for each window id.
    static func desktopNumbers(for windowIDs: [Int]) -> [Int: Int] {
        var number: [UInt64: Int] = [:]
        for display in displays() {
            for (index, space) in display.desktops.enumerated() { number[space.id] = index + 1 }
        }
        var result: [Int: Int] = [:]
        for id in windowIDs {
            if let space = spaces(forWindow: CGWindowID(id)).first, let n = number[space] { result[id] = n }
        }
        return result
    }
}
