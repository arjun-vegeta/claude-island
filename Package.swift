// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ClaudeIsland",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ClaudeIsland",
            path: "Sources/ClaudeIsland",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
