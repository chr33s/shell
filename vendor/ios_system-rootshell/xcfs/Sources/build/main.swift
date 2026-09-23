// use it from root folder:
// `xcrun swift run --package-path xcfs build [all, awk, tar, ios_system, ...]`

import FMake
import Foundation

OutputLevel.default = .error

// Platforms supported by FMake
let platforms: [Platform] = [.iPhoneOS, .iPhoneSimulator, .Catalyst]

// Additional platforms to build (visionOS - not yet supported by FMake)
let additionalPlatforms = ["xros", "xrsimulator"]  // visionOS and visionOS Simulator

let allSchemes = [
    "ios_system",
    "awk",
    "files",
    "joe",
    "shell",
    "text",
    ]

let args = ProcessInfo.processInfo.arguments

var schemes: [String]
if args.count > 1 && args[1] != "all" {
    schemes = args[1].components(separatedBy: ",")
} else {
    schemes = allSchemes
}

var checksums: [[String?]] = []

// First, do regular builds for visionOS platforms to populate DerivedData with dependencies
// This is needed because archive builds use isolated build directories and can't find
// framework dependencies that were archived separately
// Always build ios_system first as it's a common dependency
// A dedicated DerivedData keeps visionOS archives from linking a stale ios_system
// out of whichever ~/Library DerivedData folder happened to sort first.
let derivedDataPath = FileManager.default.currentDirectoryPath + "/.build/DerivedData"
for platform in additionalPlatforms {
    print("Pre-building ios_system for \(platform) to populate dependencies...")
    try sh("""
        xcodebuild build -project ios_system.xcodeproj -scheme ios_system -sdk \(platform) \
        -configuration Release -derivedDataPath \(derivedDataPath) EXCLUDED_ARCHS=x86_64
        """)
}

for scheme in schemes {
    // Build archives for FMake-supported platforms
    try xbArchive(
        dirPath: ".build",
        project: "ios_system",
        scheme: scheme,
        platforms: platforms.map { ($0, excludedArchs: $0 == .iPhoneSimulator ? [.x86_64] : []) }
    )

    // Build archives for visionOS platforms manually
    // Dependencies are already built from the pre-build step above
    // We need to add FRAMEWORK_SEARCH_PATHS to find ios_system.framework from DerivedData
    for platform in additionalPlatforms {
        let archivePath = ".build/\(scheme)-\(platform).xcarchive"
        let sdk = platform
        let configuration = "Release"
        let frameworkSearchPath = "\(derivedDataPath)/Build/Products/\(configuration)-\(sdk)"

        print("Archiving \(scheme) for \(platform)...")
        try sh("""
            xcodebuild archive -project ios_system.xcodeproj -scheme \(scheme) -sdk \(sdk) \
            -archivePath \(archivePath) \
            BUILD_FOR_DISTRIBUTION=YES SKIP_INSTALL=NO ENABLE_BITCODE=YES \
            EXCLUDED_ARCHS=x86_64 SDKROOT=\(sdk) SUPPORTED_PLATFORMS=\(sdk) \
            'FRAMEWORK_SEARCH_PATHS=$(inherited) \(frameworkSearchPath)'
            """)
    }

    // Create XCFramework with all platforms
    try cd(".build") {
        var frameworkArgs = ""
        let frameworkName = scheme
        let currentDir = FileManager.default.currentDirectoryPath

        // Add FMake-built platform archives
        for p in platforms {
            let xcarchive = "\(currentDir)/\(scheme)-\(p).xcarchive"
            let framework = "\(xcarchive)/Products/Library/Frameworks/\(frameworkName).framework"
            let dsym = "\(xcarchive)/dSYMs/\(frameworkName).framework.dSYM"
            frameworkArgs += " -framework \(framework) -debug-symbols \(dsym)"
        }

        // Add visionOS platform archives
        for platform in additionalPlatforms {
            let xcarchive = "\(currentDir)/\(scheme)-\(platform).xcarchive"
            let framework = "\(xcarchive)/Products/Library/Frameworks/\(frameworkName).framework"
            let dsym = "\(xcarchive)/dSYMs/\(frameworkName).framework.dSYM"
            frameworkArgs += " -framework \(framework) -debug-symbols \(dsym)"
        }

        // Remove old xcframework and create new one with all platforms
        try sh("rm -rf \(scheme).xcframework")
        print("Creating XCFramework with command:")
        print("xcodebuild -create-xcframework \(frameworkArgs) -output \(scheme).xcframework")
        try sh("xcodebuild -create-xcframework \(frameworkArgs) -output \(scheme).xcframework")

        // Zip and generate checksum
        let zip = "\(scheme).xcframework.zip"
        // zip -r appends to an existing archive, which kept stale slices around.
        try sh("rm -f \(zip)")
        try sh("zip --symlinks -r \(zip) \(scheme).xcframework")
        let chksum = try sha(path: zip)
        checksums.append([zip, chksum])

        // Move to organized directory
        try sh("rm -rf \(scheme)")
        try sh("mkdir \(scheme)")
        try sh("mv \(scheme).xcframework \(scheme)")
    }
}

var releaseNotes =
"""
Release notes:

\( checksums.markdown(headers: "File", "SHA 256") )

"""

try write(content: releaseNotes, atPath: ".build/release.md")
