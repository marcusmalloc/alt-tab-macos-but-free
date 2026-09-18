// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BareTab",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "BareTab", targets: ["BareTab"])],
    targets: [
        .target(name: "WindowBridge", linkerSettings: [.linkedFramework("ApplicationServices")]),
        .executableTarget(name: "BareTab", dependencies: ["WindowBridge"])
    ]
)
