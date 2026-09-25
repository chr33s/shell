// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "shell-control-host",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ShellControlHostSupport", targets: ["ShellControlHostSupport"]),
        .library(name: "ShellControlManagement", targets: ["ShellControlManagement"]),
        .library(name: "ShellControlDaemon", targets: ["ShellControlDaemon"]),
        .library(name: "ShellControlAgentAdapter", targets: ["ShellControlAgentAdapter"]),
        // The bundled, sandboxed macOS Control host (docs/specs/agent-relay.md 18.2),
        // linked by the ShellControlHost app target in shell.xcodeproj.
        .library(name: "ShellControlHostRuntime", targets: ["ShellControlHostRuntime"]),
        .executable(name: "shell-controld", targets: ["shell-controld"]),
        .executable(name: "shell-control", targets: ["shell-control"])
    ],
    dependencies: [
        .package(path: "../Packages/ShellControlCore"),
        .package(path: "../vendor/swift-argument-parser"),
        // The broker library: composed in-process by ShellControlHostRuntime,
        // and driven by the adapter end-to-end suite.
        .package(path: "../services/shell-control")
    ],
    targets: [
        .target(
            name: "ShellControlHostSupport",
            dependencies: [.product(name: "ShellControlProtocol", package: "ShellControlCore")]
        ),
        .target(
            name: "ShellControlManagement",
            dependencies: [
                "ShellControlHostSupport",
                .product(name: "ShellControlProtocol", package: "ShellControlCore"),
                .product(name: "ShellControlSecurity", package: "ShellControlCore"),
                .product(name: "ShellControlClient", package: "ShellControlCore")
            ]
        ),
        .target(
            name: "ShellControlDaemon",
            dependencies: [
                "ShellControlHostSupport",
                .product(name: "ShellControlProtocol", package: "ShellControlCore"),
                .product(name: "ShellControlSecurity", package: "ShellControlCore"),
                .product(name: "ShellControlClient", package: "ShellControlCore")
            ]
        ),
        // Claude Code and Codex adapters. They depend on no provider SDK,
        // Ghostty, terminal, SSH, or tmux-parsing code (docs/specs/agent-relay.md 2).
        .target(
            name: "ShellControlAgentAdapter",
            dependencies: [
                "ShellControlHostSupport",
                .product(name: "ShellControlProtocol", package: "ShellControlCore")
            ]
        ),
        // Broker and daemon in one process. It must never depend on
        // ShellControlManagement: the TestFlight profile cannot reach the
        // legacy installer or launchd management (docs/specs/agent-relay.md 18.2).
        .target(
            name: "ShellControlHostRuntime",
            dependencies: [
                "ShellControlDaemon",
                "ShellControlHostSupport",
                .product(name: "ShellControlBroker", package: "shell-control"),
                .product(name: "ShellControlProtocol", package: "ShellControlCore"),
                .product(name: "ShellControlSecurity", package: "ShellControlCore"),
                .product(name: "ShellControlHTTPServer", package: "ShellControlCore")
            ]
        ),
        .executableTarget(name: "shell-controld", dependencies: ["ShellControlDaemon", "ShellControlHostSupport"]),
        .executableTarget(name: "shell-control", dependencies: [
            "ShellControlManagement", "ShellControlHostSupport", "ShellControlAgentAdapter",
            .product(name: "ShellControlProtocol", package: "ShellControlCore"),
            .product(name: "ShellControlSecurity", package: "ShellControlCore"),
            .product(name: "ShellControlClient", package: "ShellControlCore"),
            .product(name: "ArgumentParser", package: "swift-argument-parser")
        ]),
        .testTarget(name: "ShellControlDaemonTests", dependencies: ["ShellControlDaemon"]),
        .testTarget(name: "ShellControlManagementTests", dependencies: [
            "ShellControlManagement", "ShellControlHostSupport",
            .product(name: "ShellControlClient", package: "ShellControlCore")
        ]),
        .testTarget(name: "ShellControlCommandTests", dependencies: ["ShellControlManagement"]),
        .testTarget(name: "ShellControlAgentAdapterTests", dependencies: [
            "ShellControlAgentAdapter", "ShellControlDaemon", "ShellControlHostSupport",
            .product(name: "ShellControlClient", package: "ShellControlCore"),
            .product(name: "ShellControlSecurity", package: "ShellControlCore"),
            .product(name: "ShellControlBroker", package: "shell-control")
        ]),
        .testTarget(name: "ShellControlHostRuntimeTests", dependencies: [
            "ShellControlHostRuntime", "ShellControlAgentAdapter", "ShellControlHostSupport",
            .product(name: "ShellControlProtocol", package: "ShellControlCore"),
            .product(name: "ShellControlSecurity", package: "ShellControlCore")
        ])
    ]
)
