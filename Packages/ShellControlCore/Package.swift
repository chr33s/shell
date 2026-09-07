// swift-tools-version: 6.2
import PackageDescription

// ShellControlCore is portable Swift: no UIKit, Ghostty, Citadel, terminal
// surface, SSH credential, or CloudKit dependency (spec.watch.md section 18).
let package = Package(
    name: "ShellControlCore",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
        .watchOS(.v26),
        .visionOS(.v26),
    ],
    products: [
        .library(name: "ShellControlProtocol", targets: ["ShellControlProtocol"]),
        .library(name: "ShellControlSecurity", targets: ["ShellControlSecurity"]),
        .library(name: "ShellControlClient", targets: ["ShellControlClient"]),
    ],
    targets: [
        .target(name: "ShellControlProtocol", path: "Sources/Protocol"),
        .target(
            name: "ShellControlSecurity",
            dependencies: ["ShellControlProtocol"],
            path: "Sources/Security"
        ),
        .target(
            name: "ShellControlClient",
            dependencies: ["ShellControlProtocol", "ShellControlSecurity"],
            path: "Sources/Client"
        ),
        .testTarget(
            name: "ShellControlCoreTests",
            dependencies: ["ShellControlProtocol", "ShellControlSecurity", "ShellControlClient"],
            path: "Tests/ShellControlCoreTests"
        ),
    ]
)
