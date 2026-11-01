// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "OpenPiP",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic, no AppKit. Everything here is unit tested.
        .target(name: "OpenPiPCore"),
        // The menu-bar app: panel, capture, socket.
        .executableTarget(name: "OpenPiP", dependencies: ["OpenPiPCore"]),
        .testTarget(name: "OpenPiPTests", dependencies: ["OpenPiPCore"]),
    ]
)
