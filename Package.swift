// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SpaceMaster",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "SpaceMaster", targets: ["SMApp"]),
        .executable(name: "sm-bench", targets: ["sm-bench"]),
    ],
    targets: [
        // No AppKit: bulk directory enumeration, parallel size scanner, safety rules, formatting.
        .target(name: "SMCore", swiftSettings: [.unsafeFlags(["-Ounchecked"], .when(configuration: .release))]),
        .executableTarget(name: "SMApp", dependencies: ["SMCore"]),
        .executableTarget(name: "sm-bench", dependencies: ["SMCore"]),
        .testTarget(name: "SMCoreTests", dependencies: ["SMCore"]),
    ]
)
