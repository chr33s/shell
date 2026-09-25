// swift-tools-version: 6.2
import PackageDescription

// The optional Shell Push Relay: a stateless APNs sender for the iPhone
// gateway profile (docs/specs/control-protocol.md section 12). It depends on the
// portable protocol and signing code only, never on approval-state storage.
let package = Package(
    name: "push-relay",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ShellPushRelay", targets: ["ShellPushRelay"]),
        .executable(name: "shell-push-relay", targets: ["shell-push-relay"])
    ],
    dependencies: [
        .package(path: "../../Packages/ShellControlCore")
    ],
    targets: [
        .target(
            name: "ShellPushRelay",
            dependencies: [
                .product(name: "ShellControlProtocol", package: "ShellControlCore"),
                .product(name: "ShellControlSecurity", package: "ShellControlCore"),
                .product(name: "ShellControlHTTPServer", package: "ShellControlCore")
            ]
        ),
        .executableTarget(name: "shell-push-relay", dependencies: ["ShellPushRelay"]),
        .testTarget(name: "ShellPushRelayTests", dependencies: ["ShellPushRelay"])
    ]
)
