// swift-tools-version: 5.9
// vendored by scripts/vendor.py — regenerated on every sync, do not edit by hand

import PackageDescription

let package = Package(
    name: "vim",
    platforms: [
        .iOS(.v14),
        .macCatalyst(.v14),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "vim", targets: ["vim", "xxd"]),
    ],
    targets: [
        .binaryTarget(
            name: "vim",
            url: "https://github.com/kitknox/vim-rootshell/releases/download/v0.1.0/vim.xcframework.zip",
            checksum: "62ab92ca4374798141b1e3d48850686e6117ec3717fd38e87d4a9136f00fdba7"
        ),
        .binaryTarget(
            name: "xxd",
            url: "https://github.com/kitknox/vim-rootshell/releases/download/v0.1.0/xxd.xcframework.zip",
            checksum: "afa36c8993d688d77bc714596a70d0e4eea82cd93f423a85cec2a3a602b9a30f"
        ),
    ]
)
