// swift-tools-version: 6.2
import PackageDescription

// The libghostty embedder API subset Shell uses, as a Swift module on swiftty's
// SwifttyCore. Names follow Ghostty's ghostty.h; there is no C ABI.
let package = Package(
    name: "GhosttyKit",
    platforms: [.iOS("27.0"), .macCatalyst("27.0"), .visionOS("27.0"), .macOS("27.0")],
    products: [
        .library(name: "GhosttyKit", targets: ["GhosttyKit"])
    ],
    dependencies: [
        .package(path: "../../vendor/swiftty")
    ],
    targets: [
        .target(
            name: "GhosttyKit",
            dependencies: [.product(name: "SwifttyCore", package: "swiftty")],
            swiftSettings: [.enableExperimentalFeature("Lifetimes")]
        ),
        .testTarget(name: "GhosttyKitTests", dependencies: ["GhosttyKit"])
    ]
)
