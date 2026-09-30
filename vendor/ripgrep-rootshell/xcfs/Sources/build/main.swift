// ripgrep_ios XCFramework Build Tool
// Usage from ripgrep_ios root: swift run --package-path xcfs build

import FMake
import Foundation

OutputLevel.default = .error

// MARK: - Helper Functions

func runAndCapture(_ cmd: String) throws -> String {
    let process = Process()
    let pipe = Pipe()

    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", cmd]
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    process.environment = ProcessInfo.processInfo.environment

    try process.run()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        throw NSError(domain: "build", code: Int(process.terminationStatus),
                      userInfo: [NSLocalizedDescriptionKey: "Command failed: \(cmd)"])
    }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

// MARK: - Platform Configuration

struct PlatformConfig {
    let name: String
    let sdk: String
    let rustTargets: [String]
    let minVersionFlag: String
    let supportedPlatformKey: String
    let isCatalyst: Bool
    let needsNightly: Bool
    let iosSystemSlice: String
}

let platforms: [PlatformConfig] = [
    PlatformConfig(
        name: "iPhoneOS",
        sdk: "iphoneos",
        rustTargets: ["aarch64-apple-ios"],
        minVersionFlag: "-miphoneos-version-min=14.0",
        supportedPlatformKey: "iPhoneOS",
        isCatalyst: false,
        needsNightly: false,
        iosSystemSlice: "ios-arm64"
    ),
    PlatformConfig(
        name: "iPhoneSimulator",
        sdk: "iphonesimulator",
        rustTargets: ["aarch64-apple-ios-sim"],
        minVersionFlag: "-mios-simulator-version-min=14.0",
        supportedPlatformKey: "iPhoneSimulator",
        isCatalyst: false,
        needsNightly: false,
        iosSystemSlice: "ios-arm64-simulator"
    ),
    PlatformConfig(
        name: "Catalyst",
        sdk: "macosx",
        rustTargets: ["aarch64-apple-ios-macabi", "x86_64-apple-ios-macabi"],
        minVersionFlag: "-target {arch}-apple-ios14.0-macabi",
        supportedPlatformKey: "MacOSX",
        isCatalyst: true,
        needsNightly: true,
        iosSystemSlice: "ios-arm64_x86_64-maccatalyst"
    ),
    PlatformConfig(
        name: "xros",
        sdk: "xros",
        rustTargets: ["aarch64-apple-visionos"],
        minVersionFlag: "-target arm64-apple-xros1.0",
        supportedPlatformKey: "XROS",
        isCatalyst: false,
        needsNightly: true,
        iosSystemSlice: "xros-arm64"
    ),
    PlatformConfig(
        name: "xrsimulator",
        sdk: "xrsimulator",
        rustTargets: ["aarch64-apple-visionos-sim"],
        minVersionFlag: "-target arm64-apple-xros1.0-simulator",
        supportedPlatformKey: "XRSimulator",
        isCatalyst: false,
        needsNightly: true,
        iosSystemSlice: "xros-arm64-simulator"
    ),
]

// MARK: - SDK & Path Functions

func sdkPath(for sdk: String) throws -> String {
    return try runAndCapture("xcrun --sdk \(sdk) --show-sdk-path")
}

func isSDKAvailable(_ sdk: String) -> Bool {
    do {
        _ = try sdkPath(for: sdk)
        return true
    } catch {
        return false
    }
}

func findIosSystemFramework(for platform: PlatformConfig) -> String? {
    let sourceRoot = FileManager.default.currentDirectoryPath
    let iosSystemRoot = URL(fileURLWithPath: sourceRoot)
        .deletingLastPathComponent()
        .appendingPathComponent("ios_system")
        .path

    let xcframeworkPath = "\(iosSystemRoot)/.build/ios_system/ios_system.xcframework"
    let slicePath = "\(xcframeworkPath)/\(platform.iosSystemSlice)"
    if FileManager.default.fileExists(atPath: "\(slicePath)/ios_system.framework") {
        return slicePath
    }

    return nil
}

// MARK: - Cargo Build

func buildRust(
    sourceRoot: String,
    platform: PlatformConfig,
    rustTarget: String,
    sdk: String,
    iosSystemPath: String,
    outputDir: String
) throws {
    let iosSystemFrameworkDir = "\(iosSystemPath)/ios_system.framework"

    // Base environment
    var env = ProcessInfo.processInfo.environment
    env["SDKROOT"] = sdk

    // Tell build.rs where to find ios_system.framework
    env["IOS_SYSTEM_FRAMEWORK_PATH"] = iosSystemPath

    // Deployment target environment variables
    if platform.sdk == "iphoneos" || platform.sdk == "iphonesimulator" {
        env["IPHONEOS_DEPLOYMENT_TARGET"] = "14.0"
    } else if platform.sdk == "xros" || platform.sdk == "xrsimulator" {
        env["XROS_DEPLOYMENT_TARGET"] = "1.0"
    }

    // Linker flags: find ios_system.framework
    let linkerFlags = "-C link-arg=-F\(iosSystemPath) -C link-arg=-framework -C link-arg=ios_system -C link-arg=-isysroot -C link-arg=\(sdk)"

    // For Catalyst, add iOSSupport framework path
    var extraFlags = ""
    if platform.isCatalyst {
        extraFlags = " -C link-arg=-iframework -C link-arg=\(sdk)/System/iOSSupport/System/Library/Frameworks"
    }

    let targetUpperEnv = rustTarget.uppercased().replacingOccurrences(of: "-", with: "_")
    env["CARGO_TARGET_\(targetUpperEnv)_RUSTFLAGS"] = "\(linkerFlags)\(extraFlags)"

    // Build command
    var cargoCmd: String
    if platform.needsNightly {
        // Tier-3 targets require nightly and -Z build-std
        cargoCmd = "cargo +nightly build -Z build-std --target \(rustTarget) --release"
    } else {
        // Ensure target is installed for tier-2 targets
        try sh("rustup target add \(rustTarget)")
        cargoCmd = "cargo build --target \(rustTarget) --release"
    }

    print("  Building Rust for \(rustTarget)...")

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "cd \(sourceRoot) && \(cargoCmd)"]
    process.environment = env

    let errPipe = Pipe()
    process.standardError = errPipe
    process.standardOutput = FileHandle.nullDevice

    try process.run()
    process.waitUntilExit()

    if process.terminationStatus != 0 {
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let errStr = String(data: errData, encoding: .utf8) ?? "unknown error"
        print("  Cargo build failed for \(rustTarget):")
        print(errStr)
        throw NSError(domain: "build", code: Int(process.terminationStatus),
                      userInfo: [NSLocalizedDescriptionKey: "Cargo build failed for \(rustTarget)"])
    }

    // Copy the dylib to the output directory
    let dylibName = "libripgrep_ios.dylib"
    let srcDylib = "\(sourceRoot)/target/\(rustTarget)/release/\(dylibName)"
    let dstDylib = "\(outputDir)/\(dylibName)"
    try sh("cp \(srcDylib) \(dstDylib)")

    print("  Built \(dstDylib)")
}

// MARK: - Framework Packaging

func createFrameworkBundle(
    name: String,
    binaryPath: String,
    platform: PlatformConfig,
    outputDir: String
) throws {
    let frameworkPath = "\(outputDir)/\(name).framework"

    try sh("rm -rf \(frameworkPath)")
    try sh("mkdir -p \(frameworkPath)")

    let minOS = (platform.sdk == "xros" || platform.sdk == "xrsimulator") ? "1.0" : "14.0"

    let infoPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
        "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleDevelopmentRegion</key>
            <string>en</string>
            <key>CFBundleExecutable</key>
            <string>\(name)</string>
            <key>CFBundleIdentifier</key>
            <string>com.ripgrep.ripgrep-ios</string>
            <key>CFBundleInfoDictionaryVersion</key>
            <string>6.0</string>
            <key>CFBundleName</key>
            <string>\(name)</string>
            <key>CFBundlePackageType</key>
            <string>FMWK</string>
            <key>CFBundleShortVersionString</key>
            <string>0.1.0</string>
            <key>CFBundleSupportedPlatforms</key>
            <array>
                <string>\(platform.supportedPlatformKey)</string>
            </array>
            <key>CFBundleVersion</key>
            <string>1</string>
            <key>MinimumOSVersion</key>
            <string>\(minOS)</string>
        </dict>
        </plist>
        """

    if platform.isCatalyst {
        // Deep bundle structure for Catalyst
        let versionsDir = "\(frameworkPath)/Versions"
        let versionADir = "\(versionsDir)/A"
        let resourcesDir = "\(versionADir)/Resources"

        try sh("mkdir -p \(resourcesDir)")
        try sh("cp \(binaryPath) \(versionADir)/\(name)")
        try write(content: infoPlist, atPath: "\(resourcesDir)/Info.plist")

        try sh("ln -sf A \(versionsDir)/Current")
        try sh("ln -sf Versions/Current/\(name) \(frameworkPath)/\(name)")
        try sh("ln -sf Versions/Current/Resources \(frameworkPath)/Resources")

        try sh("install_name_tool -id @rpath/\(name).framework/Versions/A/\(name) \(versionADir)/\(name)")
    } else {
        // Shallow bundle structure for iOS/xrOS
        try sh("cp \(binaryPath) \(frameworkPath)/\(name)")
        try write(content: infoPlist, atPath: "\(frameworkPath)/Info.plist")
        try sh("install_name_tool -id @rpath/\(name).framework/\(name) \(frameworkPath)/\(name)")
    }
}

func createFatBinary(binaries: [String], output: String) throws {
    let inputs = binaries.joined(separator: " ")
    try sh("lipo -create \(inputs) -output \(output)")
}

func createXCFramework(name: String, frameworkPaths: [String], outputDir: String) throws {
    var args = [String]()
    for path in frameworkPaths {
        args.append("-framework")
        args.append(path)
        let dsymPath = "\(path).dSYM"
        if FileManager.default.fileExists(atPath: dsymPath) {
            args.append("-debug-symbols")
            args.append(dsymPath)
        }
    }
    args.append("-output")
    args.append("\(outputDir)/\(name).xcframework")

    try sh("rm -rf \(outputDir)/\(name).xcframework")
    try sh("xcodebuild -create-xcframework \(args.joined(separator: " "))")
}

// MARK: - Main Build Process

print("ripgrep_ios XCFramework Build")
print("=============================")
print("")

let sourceRoot = FileManager.default.currentDirectoryPath
let buildDir = "\(sourceRoot)/.build"
let frameworkName = "ripgrep_ios"

try sh("mkdir -p \(buildDir)")

var frameworkPaths = [String]()

for platform in platforms {
    guard isSDKAvailable(platform.sdk) else {
        print("Skipping \(platform.name): SDK '\(platform.sdk)' not available")
        continue
    }

    guard let iosSystemPath = findIosSystemFramework(for: platform) else {
        print("Skipping \(platform.name): ios_system framework not found")
        print("  Please build ios_system first: cd ../ios_system && swift run --package-path xcfs build ios_system")
        continue
    }

    print("Building for \(platform.name)...")
    print("  SDK: \(platform.sdk)")
    print("  Rust targets: \(platform.rustTargets.joined(separator: ", "))")
    print("  ios_system: \(iosSystemPath)")

    let sdk = try sdkPath(for: platform.sdk)
    let platformBuildDir = "\(buildDir)/\(platform.name)"
    try sh("mkdir -p \(platformBuildDir)")

    var archBinaries: [String] = []

    for rustTarget in platform.rustTargets {
        let archDir = "\(platformBuildDir)/\(rustTarget)"
        try sh("mkdir -p \(archDir)")

        try buildRust(
            sourceRoot: sourceRoot,
            platform: platform,
            rustTarget: rustTarget,
            sdk: sdk,
            iosSystemPath: iosSystemPath,
            outputDir: archDir
        )

        archBinaries.append("\(archDir)/libripgrep_ios.dylib")
    }

    // Create fat binary if needed (Catalyst has arm64 + x86_64)
    let finalBinaryPath: String
    if archBinaries.count > 1 {
        print("  Creating fat binary...")
        finalBinaryPath = "\(platformBuildDir)/\(frameworkName)"
        try createFatBinary(binaries: archBinaries, output: finalBinaryPath)
    } else {
        finalBinaryPath = archBinaries[0]
    }

    // Fix the install name on the raw dylib before packaging
    try sh("install_name_tool -id @rpath/\(frameworkName).framework/\(frameworkName) \(finalBinaryPath)")

    // Create framework bundle
    print("  Creating framework bundle...")
    try createFrameworkBundle(
        name: frameworkName,
        binaryPath: finalBinaryPath,
        platform: platform,
        outputDir: platformBuildDir
    )

    // Generate dSYM
    print("  Generating dSYM...")
    let binaryInFramework = platform.isCatalyst
        ? "\(platformBuildDir)/\(frameworkName).framework/Versions/A/\(frameworkName)"
        : "\(platformBuildDir)/\(frameworkName).framework/\(frameworkName)"
    try sh("dsymutil \(binaryInFramework) -o \(platformBuildDir)/\(frameworkName).framework.dSYM")

    frameworkPaths.append("\(platformBuildDir)/\(frameworkName).framework")

    print("  Done!")
    print("")
}

guard !frameworkPaths.isEmpty else {
    print("ERROR: No platforms were built successfully")
    exit(1)
}

// Create XCFramework
print("Creating XCFramework...")
try createXCFramework(name: frameworkName, frameworkPaths: frameworkPaths, outputDir: buildDir)

// Generate checksums
print("Generating checksums...")
var checksums: [[String?]] = []

try cd(buildDir) {
    let zip = "\(frameworkName).xcframework.zip"
    try sh("rm -f \(zip)")
    try sh("zip --symlinks -r \(zip) \(frameworkName).xcframework")
    let checksum = try sha(path: zip)
    checksums.append([zip, checksum])
    print("  \(zip): \(checksum)")
}

let releaseNotes = """
    # ripgrep_ios XCFramework Release

    ## Checksums

    \(checksums.markdown(headers: "File", "SHA 256"))

    ## Platforms

    - iOS (arm64)
    - iOS Simulator (arm64)
    - Mac Catalyst (arm64, x86_64)
    - visionOS (arm64)
    - visionOS Simulator (arm64)

    ## Build Info

    - ripgrep version: 15.1.0
    - Regex engine: Rust regex (no PCRE2)
    - No C dependencies required

    """

try write(content: releaseNotes, atPath: "\(buildDir)/release.md")

print("")
print("Build complete!")
print("Output: \(buildDir)/")
print("  - \(frameworkName).xcframework")
print("  - \(frameworkName).xcframework.zip")
print("  - release.md")
