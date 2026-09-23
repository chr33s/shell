// swift-tools-version: 6.2
// vendored by scripts/vendor.py — regenerated on every sync, do not edit by hand

import PackageDescription

let package = Package(
    name: "ios_system",
    platforms: [
        .iOS(.v18),
        .macCatalyst(.v18),
        .visionOS(.v26),
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
            url: "https://github.com/kitknox/ios_system-rootshell/releases/download/v0.1.1/ios_system.xcframework.zip",
            checksum: "a2ba0979ae598ad6502b0646ebb4030c05494f900597db76a23f6693a4c85726"
        ),
        .binaryTarget(
            name: "awk",
            url: "https://github.com/kitknox/ios_system-rootshell/releases/download/v0.1.1/awk.xcframework.zip",
            checksum: "3c521da24fcfd4b42d7589394c8810ca25f960de2857e128ef7a9078a6aa12bf"
        ),
        .binaryTarget(
            name: "files",
            url: "https://github.com/kitknox/ios_system-rootshell/releases/download/v0.1.1/files.xcframework.zip",
            checksum: "c75548c67c3e1349269011a933815385a25b38b5cb4ae31e5ca372a35045191c"
        ),
        .binaryTarget(
            name: "shell",
            url: "https://github.com/kitknox/ios_system-rootshell/releases/download/v0.1.1/shell.xcframework.zip",
            checksum: "8582d18805d1d6ab6f650ec41fda404073234904344020f5dfa48b2e73ab7bec"
        ),
        .binaryTarget(
            name: "text",
            url: "https://github.com/kitknox/ios_system-rootshell/releases/download/v0.1.1/text.xcframework.zip",
            checksum: "accf13b497593b228abf28c54a2f79d4c61ec6eb825a9dc13ce13c8e84c7ac65"
        ),
    ]
)
