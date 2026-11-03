// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "DeskLight",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "LampKit"),
        .executableTarget(name: "DeskLight", dependencies: ["LampKit"]),
        .testTarget(name: "LampKitTests", dependencies: ["LampKit"]),
    ]
)
