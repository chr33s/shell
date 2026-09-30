// swift-tools-version:5.3
import PackageDescription

let package = Package(
    name: "xcfs",
    platforms: [.macOS("11")],
    dependencies: [
        .package(url: "https://github.com/holzschu/FMake", from: "0.0.19")
    ],
    targets: [
        .target(
            name: "build",
            dependencies: ["FMake"]
        ),
    ]
)
