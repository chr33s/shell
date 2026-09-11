// swift-tools-version: 5.9
// vendored by scripts/vendor.py — regenerated on every sync, do not edit by hand

import PackageDescription

let package = Package(
    name: "ios_system",
    platforms: [
        .iOS(.v14),
        .macCatalyst(.v14),
        .visionOS(.v1),
    ],
    products: [
        .library(
            name: "ios_system",
            targets: ["ios_system", "awk", "files", "shell", "text"]
        ),
    ],
    targets: [
        .binaryTarget(
            name: "ios_system",
            url: "https://github.com/kitknox/ios_system-rootshell/releases/download/v0.1.0/ios_system.xcframework.zip",
            checksum: "ce6a816ab9a901fe5df31ad6d819e19b773db32d25f612aa8318da11c6bc2cba"
        ),
        .binaryTarget(
            name: "awk",
            url: "https://github.com/kitknox/ios_system-rootshell/releases/download/v0.1.0/awk.xcframework.zip",
            checksum: "4e65e4f31a1a6b9270de0b7d2bb8514933c4693686f9659beb35db51043c324e"
        ),
        .binaryTarget(
            name: "files",
            url: "https://github.com/kitknox/ios_system-rootshell/releases/download/v0.1.0/files.xcframework.zip",
            checksum: "a55e031b73974e94b209d43343e0608a188baf887f91d45eb7a7f9d112197c90"
        ),
        .binaryTarget(
            name: "shell",
            url: "https://github.com/kitknox/ios_system-rootshell/releases/download/v0.1.0/shell.xcframework.zip",
            checksum: "7d6c39a0c5ca8bedef3c2ba97ebf8be01b0c62f3960feaa16a1a9fcb5cba2aa6"
        ),
        .binaryTarget(
            name: "text",
            url: "https://github.com/kitknox/ios_system-rootshell/releases/download/v0.1.0/text.xcframework.zip",
            checksum: "8a3bb33c303ff3c51c3ddb23748bd989afc24d88353153dd7484e0a561ea3f11"
        ),
    ]
)
