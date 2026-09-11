// swift-tools-version: 5.9
import PackageDescription

_ = Package(
    name: "xcfs",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/holzschu/FMake", from: "0.0.19")
    ],
    targets: [
        .executableTarget(
            name: "build",
            dependencies: ["FMake"]
        )
    ]
)
