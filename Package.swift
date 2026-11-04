// swift-tools-version:5.9
// Unsit: a macOS menu bar app for 10,000 steps and enough water.
// Built into Unsit.app by scripts/build-app.sh.

import PackageDescription

let package = Package(
    name: "Unsit",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Unsit",
            path: "Sources/Unsit"
        )
    ]
)
