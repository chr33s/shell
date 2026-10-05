// swift-tools-version: 6.2
import PackageDescription

// The embedder API Shell uses to drive terminal surfaces and tmux control mode,
// as a Swift module on swiftty's SwifttyCore. There is no C ABI.
let package = Package(
    name: "SwifttyKit",
    platforms: [.iOS("27.0"), .macCatalyst("27.0"), .visionOS("27.0"), .macOS("27.0")],
    products: [
        .library(name: "SwifttyKit", targets: ["SwifttyKit"])
    ],
    dependencies: [
        .package(path: "../../vendor/swiftty")
    ],
    targets: [
        .target(
            name: "SwifttyKit",
            dependencies: [.product(name: "SwifttyCore", package: "swiftty")],
            swiftSettings: [.enableExperimentalFeature("Lifetimes")]
        ),
        .testTarget(name: "SwifttyKitTests", dependencies: ["SwifttyKit"])
    ]
)
