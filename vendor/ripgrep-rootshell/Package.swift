// swift-tools-version: 5.9
// vendored by scripts/vendor.py — regenerated on every sync, do not edit by hand
import PackageDescription

let package = Package(
    name: "ripgrep_ios",
    platforms: [
        .iOS(.v14),
        .macCatalyst(.v14),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "ripgrep_ios", targets: ["ripgrep_ios"]),
    ],
    targets: [
        .binaryTarget(
            name: "ripgrep_ios",
            url: "https://api.github.com/repos/kitknox/ripgrep-rootshell/releases/assets/514744297.zip",
            checksum: "df554a63cc9bb9aa2b852766146ad882e83e001bffce5301eadad33619e16691"
        ),
    ]
)
