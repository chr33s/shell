// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "shell-control-host",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ShellControlHostSupport", targets: ["ShellControlHostSupport"]),
        .library(name: "ShellControlManagement", targets: ["ShellControlManagement"]),
        .library(name: "ShellControlDaemon", targets: ["ShellControlDaemon"]),
        .executable(name: "shell-controld", targets: ["shell-controld"]),
        .executable(name: "shell-control", targets: ["shell-control"]),
    ],
    dependencies: [
        .package(path: "../Packages/ShellControlCore"),
        .package(path: "../vendor/swift-argument-parser"),
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
                .product(name: "ShellControlClient", package: "ShellControlCore"),
            ]
        ),
        .target(
            name: "ShellControlDaemon",
            dependencies: [
                "ShellControlHostSupport",
                .product(name: "ShellControlProtocol", package: "ShellControlCore"),
                .product(name: "ShellControlSecurity", package: "ShellControlCore"),
                .product(name: "ShellControlClient", package: "ShellControlCore"),
            ]
        ),
        .executableTarget(name: "shell-controld", dependencies: ["ShellControlDaemon", "ShellControlHostSupport"]),
        .executableTarget(name: "shell-control", dependencies: [
            "ShellControlManagement", "ShellControlHostSupport",
            .product(name: "ShellControlProtocol", package: "ShellControlCore"),
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]),
        .testTarget(name: "ShellControlDaemonTests", dependencies: ["ShellControlDaemon"]),
        .testTarget(name: "ShellControlManagementTests", dependencies: ["ShellControlManagement", "ShellControlHostSupport"]),
        .testTarget(name: "ShellControlCommandTests", dependencies: ["ShellControlManagement"]),
    ]
)
