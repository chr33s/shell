// swift-tools-version: 6.0
import PackageDescription

// The Shell Control broker: enrollment, authorization policy, immutable request
// documents, resolution/dispatch records, the ordered change log, idempotency
// records, audit data, and the APNs outbox (spec.watch.md section 3).
let package = Package(
    name: "shell-control",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ShellControlBroker", targets: ["ShellControlBroker"]),
        .executable(name: "shell-control-broker", targets: ["shell-control-broker"]),
    ],
    dependencies: [
        .package(path: "../../Packages/ShellControlCore"),
    ],
    targets: [
        .target(
            name: "ShellControlBroker",
            dependencies: [
                .product(name: "ShellControlProtocol", package: "ShellControlCore"),
                .product(name: "ShellControlSecurity", package: "ShellControlCore"),
            ]
        ),
        .executableTarget(name: "shell-control-broker", dependencies: ["ShellControlBroker"]),
        .testTarget(
            name: "ShellControlBrokerTests",
            dependencies: [
                "ShellControlBroker",
                .product(name: "ShellControlClient", package: "ShellControlCore"),
            ]
        ),
    ]
)
