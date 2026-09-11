// swift-tools-version:5.9
// vendored by scripts/vendor.py — regenerated on every sync, do not edit by hand
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Citadel",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "Citadel",
            targets: ["Citadel"]
        ),
    ],
    dependencies: [
        // rootshell's public fork carries the SSH algorithm and platform fixes
        // required by Citadel.
        .package(path: "../swift-nio-ssh-rootshell"),
        .package(path: "../swift-log"),
        .package(path: "../BigInt"),
        // Pinned exactly: CMLDSA44 declares private CCryptoBoringSSL_MLDSA44_*
        // symbols and opaque struct storage sized against this release's
        // vendored BoringSSL. Re-validate the shim before moving the pin.
        .package(path: "../swift-crypto"),
        .package(path: "../swift-nio-transport-services"),
    ],
    targets: [
        .target(name: "CCitadelBcrypt"),
        .target(name: "CSntrup761"),
        // Bridges to the ML-DSA-44 already compiled inside swift-crypto's
        // CCryptoBoringSSL (whose umbrella header doesn't expose mldsa.h).
        .target(name: "CMLDSA44"),
        .target(
            name: "Citadel",
            dependencies: [
                .target(name: "CCitadelBcrypt"),
                .target(name: "CSntrup761"),
                .target(name: "CMLDSA44"),
                .product(name: "NIOSSH", package: "swift-nio-ssh-rootshell"),
                .product(name: "NIOTransportServices", package: "swift-nio-transport-services"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
                .product(name: "BigInt", package: "BigInt"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .testTarget(
            name: "CitadelTests",
            dependencies: [
                "Citadel",
                .product(name: "NIOSSH", package: "swift-nio-ssh-rootshell"),
                .product(name: "BigInt", package: "BigInt"),
                .product(name: "Logging", package: "swift-log"),
            ],
            resources: [
                .copy("TestData"),
            ]
        ),
    ]
)
