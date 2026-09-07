// swift-tools-version: 6.2
import PackageDescription

// The host side: `shell-controld` runs on the actual execution host as a
// per-user service, and `shell-control` is the CLI adapters call
// (spec.watch.md sections 3 and 17).
let package = Package(
    name: "shell-control-host",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ShellControlDaemon", targets: ["ShellControlDaemon"]),
        .executable(name: "shell-controld", targets: ["shell-controld"]),
        .executable(name: "shell-control", targets: ["shell-control"]),
    ],
    dependencies: [
        .package(path: "../Packages/ShellControlCore"),
    ],
    targets: [
        .target(
            name: "ShellControlDaemon",
            dependencies: [
                .product(name: "ShellControlProtocol", package: "ShellControlCore"),
                .product(name: "ShellControlSecurity", package: "ShellControlCore"),
                .product(name: "ShellControlClient", package: "ShellControlCore"),
            ]
        ),
        .executableTarget(name: "shell-controld", dependencies: ["ShellControlDaemon"]),
        .executableTarget(name: "shell-control", dependencies: ["ShellControlDaemon"]),
        .testTarget(name: "ShellControlDaemonTests", dependencies: ["ShellControlDaemon"]),
    ]
)
