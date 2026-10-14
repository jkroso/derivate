// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Derivate",
    platforms: [.macOS(.v14)],
    targets: [
        // Spectre's algorithm and export files, without UI.
        .target(name: "DerivateKit"),
        // The menu bar app.
        .executableTarget(name: "Derivate", dependencies: ["DerivateKit"]),
        .testTarget(name: "DerivateKitTests", dependencies: ["DerivateKit"]),
        .testTarget(name: "DerivateTests", dependencies: ["Derivate", "DerivateKit"]),
    ]
)
