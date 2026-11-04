// swift-tools-version:5.9
// Unsit: a macOS menu bar app for 10,000 steps and enough water.
// Built into Unsit.app by scripts/build-app.sh.

import PackageDescription

var products: [Product] = [
    .library(name: "UnsitCore", targets: ["UnsitCore"]),
]

var targets: [Target] = [
    // Pure Foundation logic (versions, update check). Builds and tests on any platform.
    .target(name: "UnsitCore", path: "Sources/UnsitCore"),
    .testTarget(name: "UnsitCoreTests", dependencies: ["UnsitCore"], path: "Tests/UnsitCoreTests"),
]

#if os(macOS)
// The menu bar app itself (SwiftUI, AppKit, EventKit). macOS only.
products.append(.executable(name: "Unsit", targets: ["Unsit"]))
targets.append(.executableTarget(name: "Unsit", dependencies: ["UnsitCore"], path: "Sources/Unsit"))
#endif

let package = Package(
    name: "Unsit",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
