// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Porthole",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Porthole", targets: ["Porthole"]),
    ],
    targets: [
        // Reverse-engineered FairPlay handshake (vendored C, see Sources/CFairPlay/playfair/VENDORED.md).
        .target(
            name: "CFairPlay",
            path: "Sources/CFairPlay",
            exclude: ["playfair/VENDORED.md"],
            cSettings: [.unsafeFlags(["-w"])]  // vendored code: don't drown our own warnings
        ),
        // The AirPlay mirroring receiver: discovery, handshake, streams. No UI.
        .target(
            name: "PortholeCore",
            dependencies: ["CFairPlay"],
            path: "Sources/PortholeCore"
        ),
        // The Mac app: window, video layer, menus.
        .executableTarget(
            name: "Porthole",
            dependencies: ["PortholeCore"],
            path: "Sources/Porthole"
        ),
        .testTarget(
            name: "PortholeCoreTests",
            dependencies: ["PortholeCore"],
            path: "Tests/PortholeCoreTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
