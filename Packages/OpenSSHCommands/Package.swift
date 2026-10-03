// swift-tools-version: 6.2

// OpenSSH `ssh`, `scp` and `sftp` for the ios_system interpreter — the clients
// the local SSH agent bridge serves through SSH_AUTH_SOCK
// (ssh-agent-bridge-spec.md §19).
//
// `ssh_cmd` is built from the vendored ios_system-rootshell source by
// scripts/build-openssh.sh (no upstream release ships it). OpenSSL and libssh2,
// which it links dynamically, are pinned upstream releases verified by SHA-256.
// build-openssh.sh also prepares libssh2 for App Store packaging. No visionOS
// slice exists for these, so the app links this product on iOS and Mac Catalyst only.

import PackageDescription

let package = Package(
    name: "OpenSSHCommands",
    platforms: [
        .iOS(.v18),
        .macCatalyst(.v18),
    ],
    products: [
        .library(name: "OpenSSHCommands", targets: ["ssh_cmd", "openssl", "libssh2"]),
    ],
    targets: [
        .binaryTarget(name: "ssh_cmd", path: "Artifacts/ssh_cmd.xcframework"),
        .binaryTarget(
            name: "openssl",
            url: "https://github.com/holzschu/openssl-apple/releases/download/v1.1.1w/openssl-dynamic.xcframework.zip",
            checksum: "329e8317cf9bee8e138da5d032330a7a1bd2473cf44c9c083cb2f0636abb8b80"
        ),
        .binaryTarget(name: "libssh2", path: "Artifacts/libssh2.xcframework"),
    ]
)
