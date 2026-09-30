// swift-tools-version: 5.9
// vendored by scripts/vendor.py — regenerated on every sync, do not edit by hand
import PackageDescription

let package = Package(
    name: "curl_ios-rootshell",
    platforms: [
        .iOS(.v14),
        .macCatalyst(.v14),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "curl_ios", targets: ["curl_ios"]),
    ],
    targets: [
        .binaryTarget(
            name: "curl_ios",
            url: "https://github.com/kitknox/curl_ios-rootshell/releases/download/v0.2.1/curl_ios.xcframework.zip",
            checksum: "551916152365d065b68a1ddd119bdc674d3ea7c508b603e915973b41ff651393"
        ),
    ]
)
