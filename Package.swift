// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "DeskLight",
    // 14.2: Core Audio process taps (music mode).
    platforms: [.macOS("14.2")],
    targets: [
        .target(name: "LampKit"),
        .executableTarget(name: "DeskLight", dependencies: ["LampKit"]),
        .testTarget(name: "LampKitTests", dependencies: ["LampKit"]),
    ]
)
