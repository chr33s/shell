// Vim iOS XCFramework Build Tool
// Usage from the repository root: swift run --package-path xcfs build

import FMake
import Foundation

OutputLevel.default = .error

let vimVersion = "9.2"

// MARK: - Helper Functions

/// Run a command and capture its output
func runAndCapture(_ cmd: String) throws -> String {
    let process = Process()
    let pipe = Pipe()

    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", cmd]
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    process.environment = ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"]

    try process.run()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        throw NSError(domain: "build", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "Command failed: \(cmd)"])
    }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

// MARK: - Platform Configuration

struct PlatformConfig {
    let name: String           // Display name and build output directory
    let archiveName: String    // Name used in ios_system archive (matches FMake)
    let sdk: String
    let architectures: [String]
    let minVersionFlag: String
    let hostTriple: String
    let supportedPlatformKey: String
    let isCatalyst: Bool
}

let platforms: [PlatformConfig] = [
    PlatformConfig(
        name: "iPhoneOS",
        archiveName: "iPhoneOS",
        sdk: "iphoneos",
        architectures: ["arm64"],
        minVersionFlag: "-miphoneos-version-min=14.0",
        hostTriple: "armv7-apple-darwin",
        supportedPlatformKey: "iPhoneOS",
        isCatalyst: false
    ),
    PlatformConfig(
        name: "iPhoneSimulator",
        archiveName: "iPhoneSimulator",
        sdk: "iphonesimulator",
        architectures: ["arm64"],
        minVersionFlag: "-mios-simulator-version-min=14.0",
        hostTriple: "armv7-apple-darwin",
        supportedPlatformKey: "iPhoneSimulator",
        isCatalyst: false
    ),
    PlatformConfig(
        name: "Catalyst",
        archiveName: "Catalyst",
        sdk: "macosx",
        architectures: ["arm64", "x86_64"],
        minVersionFlag: "-target {arch}-apple-ios14.0-macabi",
        hostTriple: "armv7-apple-darwin",
        supportedPlatformKey: "MacOSX",
        isCatalyst: true
    ),
    PlatformConfig(
        name: "xros",
        archiveName: "xros",
        sdk: "xros",
        architectures: ["arm64"],
        minVersionFlag: "-target arm64-apple-xros1.0",
        hostTriple: "armv7-apple-darwin",
        supportedPlatformKey: "XROS",
        isCatalyst: false
    ),
    PlatformConfig(
        name: "xrsimulator",
        archiveName: "xrsimulator",
        sdk: "xrsimulator",
        architectures: ["arm64"],
        minVersionFlag: "-target arm64-apple-xros1.0-simulator",
        hostTriple: "armv7-apple-darwin",
        supportedPlatformKey: "XRSimulator",
        isCatalyst: false
    ),
]

// MARK: - SDK and Framework Functions

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
    let vimRoot = FileManager.default.currentDirectoryPath
    let iosSystemRoot = URL(fileURLWithPath: vimRoot)
        .deletingLastPathComponent()
        .appendingPathComponent("ios_system")
        .path

    // Try xcframework first
    let xcframeworkPath = "\(iosSystemRoot)/.build/ios_system/ios_system.xcframework"
    if FileManager.default.fileExists(atPath: xcframeworkPath) {
        // Extract the right platform from xcframework
        let platformDir: String
        switch platform.sdk {
        case "iphoneos":
            platformDir = "ios-arm64"
        case "iphonesimulator":
            platformDir = "ios-arm64-simulator"
        case "macosx":
            platformDir = "ios-arm64-maccatalyst"
        case "xros":
            platformDir = "xros-arm64"
        case "xrsimulator":
            platformDir = "xros-arm64-simulator"
        default:
            platformDir = "ios-arm64"
        }
        let frameworkInXC = "\(xcframeworkPath)/\(platformDir)"
        if FileManager.default.fileExists(atPath: frameworkInXC) {
            return frameworkInXC
        }
    }

    // Try archive paths (FMake style) - use archiveName to match FMake naming
    let archivePaths = [
        "\(iosSystemRoot)/.build/ios_system-\(platform.archiveName).xcarchive/Products/Library/Frameworks",
        "\(iosSystemRoot)/.build/ios_system-iPhoneOS.xcarchive/Products/Library/Frameworks",
        "\(iosSystemRoot)/.build/ios_system-iPhoneSimulator.xcarchive/Products/Library/Frameworks",
        "\(iosSystemRoot)/.build/ios_system-Catalyst.xcarchive/Products/Library/Frameworks",
    ]

    for path in archivePaths {
        if FileManager.default.fileExists(atPath: "\(path)/ios_system.framework") {
            return path
        }
    }

    // Try DerivedData
    let derivedDataPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Developer/Xcode/DerivedData")
        .path

    if let derivedContents = try? FileManager.default.contentsOfDirectory(atPath: derivedDataPath),
       let iosSystemDir = derivedContents.first(where: { $0.hasPrefix("ios_system-") }) {
        let configuration = "Release"
        let sdk = platform.sdk
        let frameworkPath = "\(derivedDataPath)/\(iosSystemDir)/Build/Products/\(configuration)-\(sdk)"
        if FileManager.default.fileExists(atPath: "\(frameworkPath)/ios_system.framework") {
            return frameworkPath
        }
    }

    return nil
}

func minVersionFlag(for platform: PlatformConfig, arch: String) -> String {
    if platform.minVersionFlag.contains("{arch}") {
        return platform.minVersionFlag.replacingOccurrences(of: "{arch}", with: arch)
    }
    return platform.minVersionFlag
}

// MARK: - Build Functions

func configureVim(platform: PlatformConfig, arch: String, sdkPath: String, frameworkPath: String) throws {
    let versionFlag = minVersionFlag(for: platform, arch: arch)

    // For Catalyst, we need to add iOSSupport framework path for UIKit
    // Also undefine HAVE_TERMCAP_H to avoid conflicts with macOS ncurses
    var catalystFlags = ""
    if platform.isCatalyst {
        catalystFlags = " -iframework \(sdkPath)/System/iOSSupport/System/Library/Frameworks -UHAVE_TERMCAP_H"
    }

    let cflags = "-DEXITFREE -arch \(arch) -O2 -g \(versionFlag) -isysroot \(sdkPath)\(catalystFlags)"
    let ldflags = "-shared -arch \(arch) -O2 -g \(versionFlag) -isysroot \(sdkPath)\(catalystFlags) -F\(frameworkPath) -framework ios_system"

    print("  Configuring for \(platform.name) \(arch)...")

    // Configure vim - disable tgetent to use vim's builtin termlib
    // iOS doesn't have termcap/ncurses, and Catalyst's ncurses conflicts with our termlib
    // vim_cv_tgetent=non-zero tells configure that tgetent doesn't work
    // ac_cv_search_tgetent=no prevents searching for terminal libraries
    try sh("""
        ./configure \
            vim_cv_toupper_broken=no \
            vim_cv_terminfo=no \
            vim_cv_tgetent=non-zero \
            ac_cv_search_tgetent=no \
            vim_cv_memmove_handles_overlap=no \
            vim_cv_memcpy_handles_overlap=no \
            vim_cv_bcopy_handles_overlap=no \
            vim_cv_tty_group=world \
            vim_cv_stat_ignores_slash=yes \
            vim_cv_getcwd_broken=no \
            --with-features=huge \
            --disable-channel \
            --disable-terminal \
            --disable-cscope \
            --disable-luainterp \
            --disable-pythoninterp \
            --disable-python3interp \
            --disable-gui \
            --without-x \
            CC=clang \
            CXX=clang++ \
            CFLAGS="\(cflags)" \
            CPPFLAGS="\(cflags)" \
            CXXFLAGS="\(cflags)" \
            LDFLAGS="\(ldflags)" \
            --build=x86_64-apple-darwin \
            --host=\(platform.hostTriple)
        """)

    // iOS doesn't have termcap/ncurses library, so we need to use vim's builtin termlib
    // Patch config.h to disable system termcap - configure doesn't respect our cache vars properly
    print("  Patching config.h to disable system termcap...")
    try sh("""
        sed -i '' 's/^#define HAVE_TGETENT 1$/\\/\\* #undef HAVE_TGETENT - iOS uses builtin termlib \\*\\//' src/auto/config.h
        sed -i '' 's/^#define HAVE_DEL_CURTERM 1$/\\/\\* #undef HAVE_DEL_CURTERM - not on iOS \\*\\//' src/auto/config.h
        sed -i '' 's/^#define HAVE_TERMCAP_H 1$/\\/\\* #undef HAVE_TERMCAP_H - iOS uses builtin termlib \\*\\//' src/auto/config.h
        """)

    // Patch the Makefile to add termlib.o to the object list and add compilation rule
    // Use idempotent commands to avoid duplicates when rebuilding
    print("  Patching Makefile for builtin termlib...")
    // Only add termlib.o if not already present
    try sh("""
        if ! grep -q 'objects/termlib\\.o' src/Makefile; then
            sed -i '' 's/^OBJ = /OBJ = objects\\/termlib.o /' src/Makefile
        fi
        """)
    // Add compilation rule for termlib.o only if not already present
    try sh(#"""
        if ! grep -q 'objects/termlib.o:' src/Makefile; then
            echo '' >> src/Makefile
            echo '# Builtin termlib for iOS (no ncurses available)' >> src/Makefile
            echo 'objects/termlib.o: termlib.c objects/.dirstamp' >> src/Makefile
            echo '	$(CCC) -o $@ termlib.c' >> src/Makefile
        fi
        """#)

    // Remove AppKit (not on iOS) and ncurses (using builtin termlib) from linker flags
    // Add Foundation for Objective-C runtime
    print("  Removing iOS-incompatible linker flags...")
    try sh("""
        sed -i '' 's/-framework AppKit/-framework UIKit -framework Foundation/g' src/auto/config.mk
        sed -i '' 's/-lncurses//g' src/auto/config.mk
        """)
}

func buildVim() throws {
    print("  Building...")
    try sh("make -j8")
}

func cleanVim() throws {
    try sh("make distclean 2>/dev/null || true")
}

func createFrameworkBundle(
    name: String,
    binaryPath: String,
    platform: PlatformConfig,
    outputDir: String
) throws {
    let frameworkPath = "\(outputDir)/\(name).framework"

    try sh("rm -rf \(frameworkPath)")
    try sh("mkdir -p \(frameworkPath)")

    // Create Info.plist content
    let infoPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleDevelopmentRegion</key>
            <string>en</string>
            <key>CFBundleExecutable</key>
            <string>\(name)</string>
            <key>CFBundleIdentifier</key>
            <string>com.vim.\(name)</string>
            <key>CFBundleInfoDictionaryVersion</key>
            <string>6.0</string>
            <key>CFBundleName</key>
            <string>\(name)</string>
            <key>CFBundlePackageType</key>
            <string>FMWK</string>
            <key>CFBundleShortVersionString</key>
            <string>\(vimVersion)</string>
            <key>CFBundleSupportedPlatforms</key>
            <array>
                <string>\(platform.supportedPlatformKey)</string>
            </array>
            <key>CFBundleVersion</key>
            <string>1</string>
            <key>MinimumOSVersion</key>
            <string>14.0</string>
        </dict>
        </plist>
        """

    if platform.isCatalyst {
        // Mac Catalyst requires deep bundle structure:
        // vim.framework/
        //   Versions/
        //     A/
        //       vim (binary)
        //       Resources/
        //         Info.plist
        //     Current -> A
        //   vim -> Versions/Current/vim
        //   Resources -> Versions/Current/Resources
        let versionsDir = "\(frameworkPath)/Versions"
        let versionADir = "\(versionsDir)/A"
        let resourcesDir = "\(versionADir)/Resources"

        try sh("mkdir -p \(resourcesDir)")

        // Copy binary to Versions/A/
        try sh("cp \(binaryPath) \(versionADir)/\(name)")

        // Write Info.plist to Versions/A/Resources/
        try write(content: infoPlist, atPath: "\(resourcesDir)/Info.plist")

        // Create symlinks
        try sh("ln -sf A \(versionsDir)/Current")
        try sh("ln -sf Versions/Current/\(name) \(frameworkPath)/\(name)")
        try sh("ln -sf Versions/Current/Resources \(frameworkPath)/Resources")

        // Set install name
        try sh("install_name_tool -id @rpath/\(name).framework/Versions/A/\(name) \(versionADir)/\(name)")
    } else {
        // iOS and other platforms use shallow bundle structure:
        // vim.framework/
        //   Info.plist
        //   vim (binary)

        // Copy binary
        try sh("cp \(binaryPath) \(frameworkPath)/\(name)")

        // Write Info.plist
        try write(content: infoPlist, atPath: "\(frameworkPath)/Info.plist")

        // Set install name
        try sh("install_name_tool -id @rpath/\(name).framework/\(name) \(frameworkPath)/\(name)")
    }
}

func createFatBinary(binaries: [(arch: String, path: String)], output: String) throws {
    let inputs = binaries.map { $0.path }.joined(separator: " ")
    try sh("lipo -create \(inputs) -output \(output)")
}

func createXCFramework(name: String, frameworkPaths: [String], outputDir: String) throws {
    var args = [String]()
    for path in frameworkPaths {
        args.append("-framework")
        args.append(path)
        // Add dSYM if it exists alongside the framework
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

print("Vim iOS XCFramework Build")
print("=========================")
print("")

let vimRoot = FileManager.default.currentDirectoryPath
let buildDir = "\(vimRoot)/.build"

// Create build directory
try sh("mkdir -p \(buildDir)")

var vimFrameworkPaths = [String]()
var xxdFrameworkPaths = [String]()

for platform in platforms {
    // Check if SDK is available
    guard isSDKAvailable(platform.sdk) else {
        print("Skipping \(platform.name): SDK '\(platform.sdk)' not available")
        continue
    }

    // Find ios_system framework
    guard let frameworkSearchPath = findIosSystemFramework(for: platform) else {
        print("Skipping \(platform.name): ios_system framework not found")
        print("  Please build ios_system first: cd ../ios_system && swift run --package-path xcfs build ios_system")
        continue
    }

    print("Building for \(platform.name)...")
    print("  SDK: \(platform.sdk)")
    print("  Architectures: \(platform.architectures.joined(separator: ", "))")
    print("  ios_system: \(frameworkSearchPath)")

    let sdk = try sdkPath(for: platform.sdk)
    let platformBuildDir = "\(buildDir)/\(platform.name)"
    try sh("mkdir -p \(platformBuildDir)")

    var archBinaries: [(arch: String, vimPath: String, xxdPath: String)] = []

    for arch in platform.architectures {
        let archDir = "\(platformBuildDir)/\(arch)"
        try sh("mkdir -p \(archDir)")

        // Clean and configure
        try cleanVim()
        try configureVim(platform: platform, arch: arch, sdkPath: sdk, frameworkPath: frameworkSearchPath)

        // Build
        try buildVim()

        // Copy binaries
        try sh("cp src/vim \(archDir)/vim")
        try sh("cp src/xxd/xxd \(archDir)/xxd")

        archBinaries.append((arch: arch, vimPath: "\(archDir)/vim", xxdPath: "\(archDir)/xxd"))
    }

    // Create fat binaries if needed
    let finalVimPath: String
    let finalXxdPath: String

    if archBinaries.count > 1 {
        print("  Creating fat binaries...")
        finalVimPath = "\(platformBuildDir)/vim"
        finalXxdPath = "\(platformBuildDir)/xxd"
        try createFatBinary(binaries: archBinaries.map { ($0.arch, $0.vimPath) }, output: finalVimPath)
        try createFatBinary(binaries: archBinaries.map { ($0.arch, $0.xxdPath) }, output: finalXxdPath)
    } else {
        finalVimPath = archBinaries[0].vimPath
        finalXxdPath = archBinaries[0].xxdPath
    }

    // Create framework bundles
    print("  Creating framework bundles...")
    try createFrameworkBundle(name: "vim", binaryPath: finalVimPath, platform: platform, outputDir: platformBuildDir)
    try createFrameworkBundle(name: "xxd", binaryPath: finalXxdPath, platform: platform, outputDir: platformBuildDir)

    // Generate dSYM bundles for crash symbolication
    print("  Generating dSYM bundles...")
    let vimBinaryInFramework = platform.isCatalyst
        ? "\(platformBuildDir)/vim.framework/Versions/A/vim"
        : "\(platformBuildDir)/vim.framework/vim"
    let xxdBinaryInFramework = platform.isCatalyst
        ? "\(platformBuildDir)/xxd.framework/Versions/A/xxd"
        : "\(platformBuildDir)/xxd.framework/xxd"

    try sh("dsymutil \(vimBinaryInFramework) -o \(platformBuildDir)/vim.framework.dSYM")
    try sh("dsymutil \(xxdBinaryInFramework) -o \(platformBuildDir)/xxd.framework.dSYM")

    vimFrameworkPaths.append("\(platformBuildDir)/vim.framework")
    xxdFrameworkPaths.append("\(platformBuildDir)/xxd.framework")

    print("  Done!")
    print("")
}

// Create XCFrameworks
guard !vimFrameworkPaths.isEmpty else {
    print("ERROR: No platforms were built successfully")
    exit(1)
}

print("Creating XCFrameworks...")
try createXCFramework(name: "vim", frameworkPaths: vimFrameworkPaths, outputDir: buildDir)
try createXCFramework(name: "xxd", frameworkPaths: xxdFrameworkPaths, outputDir: buildDir)

// Generate checksums
print("Generating checksums...")
var checksums: [[String?]] = []

try cd(buildDir) {
    for framework in ["vim", "xxd"] {
        let zip = "\(framework).xcframework.zip"
        try sh("rm -f \(zip)")
        try sh("zip --symlinks -r \(zip) \(framework).xcframework")
        let checksum = try sha(path: zip)
        checksums.append([zip, checksum])
        print("  \(zip): \(checksum)")
    }
}

// Write release notes
let releaseNotes = """
    # Vim iOS XCFramework Release

    ## Checksums

    \(checksums.markdown(headers: "File", "SHA 256"))

    ## Platforms

    - iOS (arm64)
    - iOS Simulator (arm64)
    - Mac Catalyst (arm64, x86_64)
    - visionOS (arm64)
    - visionOS Simulator (arm64)

    ## Build Info

    - Vim version: \(vimVersion)
    - No Lua interpreter
    - No Python interpreter
    - Features: huge

    """

try write(content: releaseNotes, atPath: "\(buildDir)/release.md")

print("")
print("Build complete!")
print("Output: \(buildDir)/")
print("  - vim.xcframework")
print("  - xxd.xcframework")
print("  - vim.xcframework.zip")
print("  - xxd.xcframework.zip")
print("  - release.md")
