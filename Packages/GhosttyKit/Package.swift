// swift-tools-version: 6.2
import PackageDescription

// The libghostty embedder API subset Shell uses (Sources/GhosttyKit/include/
// ghostty.h), implemented in Swift by GhosttyRuntime on swiftty's SwifttyCore.
let package = Package(
    name: "GhosttyKit",
    platforms: [.iOS("27.0"), .macCatalyst("27.0"), .visionOS("27.0"), .macOS("27.0")],
    products: [
        .library(name: "GhosttyKit", targets: ["GhosttyKit", "GhosttyRuntime"])
    ],
    dependencies: [
        .package(path: "../../vendor/swiftty")
    ],
    targets: [
        .target(name: "GhosttyKit"),
        .target(
            name: "GhosttyRuntime",
            dependencies: ["GhosttyKit", .product(name: "SwifttyCore", package: "swiftty")],
            swiftSettings: [.enableExperimentalFeature("Lifetimes")]
        ),
        .testTarget(name: "GhosttyRuntimeTests", dependencies: ["GhosttyRuntime", "GhosttyKit"])
    ]
)
