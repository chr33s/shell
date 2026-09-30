// swift-tools-version: 5.9
// vendored by scripts/vendor.py — regenerated on every sync, do not edit by hand
import PackageDescription

let package = Package(
    name: "libarchive_ios-rootshell",
    platforms: [
        .iOS(.v14),
        .macCatalyst(.v14),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "libarchive_ios", targets: ["libarchive_ios"]),
    ],
    targets: [
        .binaryTarget(
            name: "libarchive_ios",
            url: "https://github.com/kitknox/libarchive_ios-rootshell/releases/download/v0.1.0/libarchive_ios.xcframework.zip",
            checksum: "d90c091df5a38bd2fa1b70dfd95957be721884be3fbe562d77ea77b5631b4db8"
        ),
    ]
)
