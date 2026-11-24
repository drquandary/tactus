// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Tactus",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TactusCore", targets: ["TactusCore"]),
        .library(name: "TactusModules", targets: ["TactusModules"]),
        .executable(name: "tactus", targets: ["tactus"]),
    ],
    targets: [
        // The motor, finger detection, patterns, the command protocol and the pure signal logic.
        .target(name: "TactusCore"),
        // The built-in modules: signals, access, music, games, bridge and the texture window.
        .target(name: "TactusModules", dependencies: ["TactusCore"]),
        // The command-line tool and menu bar host.
        .executableTarget(name: "tactus", dependencies: ["TactusCore", "TactusModules"]),
        .testTarget(name: "TactusCoreTests", dependencies: ["TactusCore"]),
    ]
)
