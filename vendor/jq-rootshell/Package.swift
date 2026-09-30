// swift-tools-version: 5.9
// vendored by scripts/vendor.py — regenerated on every sync, do not edit by hand
import PackageDescription

let package = Package(
    name: "jq-rootshell",
    platforms: [
        .iOS(.v15),
        .macCatalyst(.v15),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "jq_ios", targets: ["jq_ios"]),
    ],
    targets: [
        .binaryTarget(
            name: "jq_ios",
            url: "https://github.com/kitknox/jq-rootshell/releases/download/v0.1.0/jq_ios.xcframework.zip",
            checksum: "eb59e3f8e49c6ce4d122829bdc286da3cd9e3ccf8dc737e898b4650ef579d2c5"
        ),
    ]
)
