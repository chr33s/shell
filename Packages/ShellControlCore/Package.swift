// swift-tools-version: 6.2
import PackageDescription

// ShellControlCore is portable Swift: no UIKit, Swiftty, Citadel, terminal
// surface, SSH credential, or CloudKit dependency (docs/specs/control-protocol.md section 20).
let package = Package(
    name: "ShellControlCore",
    platforms: [
        .macOS("27.0"),
        .iOS("27.0"),
        .watchOS("27.0"),
        .visionOS("27.0")
    ],
    products: [
        .library(name: "ShellControlProtocol", targets: ["ShellControlProtocol"]),
        .library(name: "ShellControlSecurity", targets: ["ShellControlSecurity"]),
        .library(name: "ShellControlClient", targets: ["ShellControlClient"]),
        /// macOS services only (broker, push relay); never linked by an app.
        .library(name: "ShellControlHTTPServer", targets: ["ShellControlHTTPServer"])
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
        .target(
            name: "ShellControlHTTPServer",
            dependencies: ["ShellControlProtocol"],
            path: "Sources/HTTPServer"
        ),
        .testTarget(
            name: "ShellControlCoreTests",
            dependencies: ["ShellControlProtocol", "ShellControlSecurity", "ShellControlClient"],
            path: "Tests/ShellControlCoreTests"
        )
    ]
)
