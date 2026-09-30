// libarchive_ios XCFramework Build Tool
// Usage from libarchive_ios root: swift run --package-path xcfs build

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
    process.environment = ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"]

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
    let architectures: [String]
    let minVersionFlag: String
    let cmakeSystemName: String
    let cmakeDeploymentTarget: String
    let supportedPlatformKey: String
    let isCatalyst: Bool
    let iosSystemSlice: String
}

let platforms: [PlatformConfig] = [
    PlatformConfig(
        name: "iPhoneOS",
        sdk: "iphoneos",
        architectures: ["arm64"],
        minVersionFlag: "-miphoneos-version-min=14.0",
        cmakeSystemName: "iOS",
        cmakeDeploymentTarget: "14.0",
        supportedPlatformKey: "iPhoneOS",
        isCatalyst: false,
        iosSystemSlice: "ios-arm64"
    ),
    PlatformConfig(
        name: "iPhoneSimulator",
        sdk: "iphonesimulator",
        architectures: ["arm64"],
        minVersionFlag: "-mios-simulator-version-min=14.0",
        cmakeSystemName: "iOS",
        cmakeDeploymentTarget: "14.0",
        supportedPlatformKey: "iPhoneSimulator",
        isCatalyst: false,
        iosSystemSlice: "ios-arm64-simulator"
    ),
    PlatformConfig(
        name: "Catalyst",
        sdk: "macosx",
        architectures: ["arm64", "x86_64"],
        minVersionFlag: "-target {arch}-apple-ios14.0-macabi",
        cmakeSystemName: "iOS",
        cmakeDeploymentTarget: "14.0",
        supportedPlatformKey: "MacOSX",
        isCatalyst: true,
        iosSystemSlice: "ios-arm64_x86_64-maccatalyst"
    ),
    PlatformConfig(
        name: "xros",
        sdk: "xros",
        architectures: ["arm64"],
        minVersionFlag: "-target arm64-apple-xros1.0",
        cmakeSystemName: "visionOS",
        cmakeDeploymentTarget: "1.0",
        supportedPlatformKey: "XROS",
        isCatalyst: false,
        iosSystemSlice: "xros-arm64"
    ),
    PlatformConfig(
        name: "xrsimulator",
        sdk: "xrsimulator",
        architectures: ["arm64"],
        minVersionFlag: "-target arm64-apple-xros1.0-simulator",
        cmakeSystemName: "visionOS",
        cmakeDeploymentTarget: "1.0",
        supportedPlatformKey: "XRSimulator",
        isCatalyst: false,
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

func minVersionFlag(for platform: PlatformConfig, arch: String) -> String {
    if platform.minVersionFlag.contains("{arch}") {
        return platform.minVersionFlag.replacingOccurrences(of: "{arch}", with: arch)
    }
    return platform.minVersionFlag
}

func findIosSystemFramework(for platform: PlatformConfig) -> String? {
    let sourceRoot = FileManager.default.currentDirectoryPath
    let iosSystemRoot = ProcessInfo.processInfo.environment["IOS_SYSTEM_SOURCE_DIR"]
        ?? URL(fileURLWithPath: sourceRoot)
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

// MARK: - Source Configuration

let sourceRoot = FileManager.default.currentDirectoryPath
let siblingRoot = URL(fileURLWithPath: sourceRoot).deletingLastPathComponent()

/// Path to the upstream libarchive source checkout (for CMake build + headers)
let libarchiveSourcePath: String = {
    return ProcessInfo.processInfo.environment["LIBARCHIVE_SOURCE_DIR"]
        ?? siblingRoot
        .appendingPathComponent("libarchive")
        .path
}()

/// Path to the upstream xz source checkout (for liblzma headers)
let xzSourcePath: String = {
    return ProcessInfo.processInfo.environment["XZ_SOURCE_DIR"]
        ?? siblingRoot
        .appendingPathComponent("xz")
        .path
}()

/// Path to the xz_ios build (for liblzma.a)
let xzIosBuildPath: String = {
    let xzIosSourcePath = ProcessInfo.processInfo.environment["XZ_IOS_SOURCE_DIR"]
        ?? siblingRoot
        .appendingPathComponent("xz_ios")
        .path
    return URL(fileURLWithPath: xzIosSourcePath)
        .appendingPathComponent(".build")
        .path
}()

/// Path to our patched tool sources
let patchedSourcePath: String = {
    return "\(sourceRoot)/src"
}()

/// All tool source files to compile (relative to their subdirectory in patchedSourcePath)
let toolSources: [(subdir: String, file: String)] = [
    // tar
    ("tar", "bsdtar.c"),
    ("tar", "cmdline.c"),
    ("tar", "creation_set.c"),
    ("tar", "read.c"),
    ("tar", "subst.c"),
    ("tar", "util.c"),
    ("tar", "write.c"),
    // cat
    ("cat", "bsdcat.c"),
    ("cat", "cmdline.c"),
    // cpio
    ("cpio", "cpio.c"),
    ("cpio", "cmdline.c"),
    // unzip
    ("unzip", "bsdunzip.c"),
    ("unzip", "cmdline.c"),
    // libarchive_fe (shared frontend)
    ("libarchive_fe", "lafe_err.c"),
    ("libarchive_fe", "lafe_getline.c"),
    ("libarchive_fe", "line_reader.c"),
    ("libarchive_fe", "passphrase.c"),
]

/// Globals file
let globalsSource = "libarchive_ios_globals.c"

// MARK: - Step 1: Build libarchive.a via CMake

func findLiblzma(platform: PlatformConfig, arch: String) -> (staticLib: String, headers: String)? {
    // liblzma.a from xz_ios build
    let liblzmaPath = "\(xzIosBuildPath)/\(platform.name)/\(arch)/lzma_cmake/liblzma.a"
    let lzmaHeaders = "\(xzSourcePath)/src/liblzma/api"

    if FileManager.default.fileExists(atPath: liblzmaPath) &&
       FileManager.default.fileExists(atPath: lzmaHeaders) {
        return (liblzmaPath, lzmaHeaders)
    }
    return nil
}

func buildLibarchive(platform: PlatformConfig, arch: String,
                     sdk: String, lzmaInfo: (staticLib: String, headers: String)?,
                     outputDir: String) throws {
    let cmakeBuildDir = "\(outputDir)/libarchive_cmake"
    try sh("rm -rf \(cmakeBuildDir)")
    try sh("mkdir -p \(cmakeBuildDir)")

    let versionFlag = minVersionFlag(for: platform, arch: arch)

    var cmakeCFlags = "-DTARGET_OS_IPHONE=1"
    var extraCMakeFlags = ""

    if platform.isCatalyst {
        cmakeCFlags += " -target \(arch)-apple-ios14.0-macabi"
        cmakeCFlags += " -iframework \(sdk)/System/iOSSupport/System/Library/Frameworks"
        extraCMakeFlags += " -DCMAKE_C_COMPILER_TARGET=\(arch)-apple-ios14.0-macabi"
    } else {
        cmakeCFlags += " \(versionFlag)"
    }

    if platform.sdk == "iphonesimulator" {
        extraCMakeFlags += " -DCMAKE_OSX_SYSROOT=iphonesimulator"
    } else if platform.sdk == "xrsimulator" {
        extraCMakeFlags += " -DCMAKE_OSX_SYSROOT=xrsimulator"
    }

    // Add lzma include path if available
    if let lzma = lzmaInfo {
        cmakeCFlags += " -I\(lzma.headers)"
        extraCMakeFlags += " -DLIBLZMA_INCLUDE_DIR=\(lzma.headers)"
        extraCMakeFlags += " -DLIBLZMA_LIBRARY=\(lzma.staticLib)"
        extraCMakeFlags += " -DLIBLZMA_HAS_AUTO_DECODER=ON"
        extraCMakeFlags += " -DLIBLZMA_HAS_EASY_ENCODER=ON"
        extraCMakeFlags += " -DLIBLZMA_HAS_LZMA_PRESET=ON"
    }

    print("  Configuring libarchive via CMake for \(platform.name) \(arch)...")
    let cmakeCmd = """
        cmake -B \(cmakeBuildDir) \
          -S \(libarchiveSourcePath) \
          -DCMAKE_SYSTEM_NAME=\(platform.cmakeSystemName) \
          -DCMAKE_OSX_ARCHITECTURES=\(arch) \
          -DCMAKE_OSX_DEPLOYMENT_TARGET=\(platform.cmakeDeploymentTarget) \
          -DCMAKE_OSX_SYSROOT=\(sdk) \
          -DBUILD_SHARED_LIBS=OFF \
          -DENABLE_TAR=OFF \
          -DENABLE_CAT=OFF \
          -DENABLE_CPIO=OFF \
          -DENABLE_UNZIP=OFF \
          -DENABLE_TEST=OFF \
          -DENABLE_ACL=OFF \
          -DENABLE_XATTR=OFF \
          -DZSTD_FOUND=OFF \
          -DENABLE_LIBXML2=OFF \
          -DENABLE_EXPAT=OFF \
          -DCMAKE_C_FLAGS="\(cmakeCFlags)" \
          \(extraCMakeFlags) \
          -G "Unix Makefiles"
        """
    try sh(cmakeCmd)

    print("  Building libarchive.a...")
    let ncpu = ProcessInfo.processInfo.processorCount
    try sh("cmake --build \(cmakeBuildDir) -j\(ncpu) --target archive_static")
}

// MARK: - Step 2: Compile patched tool sources

func compileToolSources(platform: PlatformConfig, arch: String,
                        sdk: String, cmakeBuildDir: String,
                        lzmaHeaders: String?,
                        outputDir: String) throws {
    let objDir = "\(outputDir)/tool_obj"
    try sh("mkdir -p \(objDir)")

    let versionFlag = minVersionFlag(for: platform, arch: arch)

    // Include paths (order matters — our config.h must come first):
    // 1. patchedSourcePath: our config.h, ios_error.h, libarchive_ios_setup.h
    // 2. Each tool's subdirectory for its own headers
    // 3. libarchive source for archive.h / archive_entry.h
    // 4. CMake build dir for generated config (not used, but cmake may create headers)
    var includePaths = [
        patchedSourcePath,                               // our config.h (must be first)
        "\(patchedSourcePath)/libarchive_fe",            // lafe_err.h, passphrase.h, etc.
        "\(libarchiveSourcePath)/libarchive",            // archive.h, archive_entry.h
    ]
    if let lzmaH = lzmaHeaders {
        includePaths.append(lzmaH)
    }

    let includeFlags = includePaths.map { "-I\($0)" }.joined(separator: " ")

    var cFlags = "-arch \(arch) \(versionFlag) -isysroot \(sdk) -O2"
    cFlags += " \(includeFlags)"
    cFlags += " -DHAVE_CONFIG_H -DTARGET_OS_IPHONE=1"

    if platform.isCatalyst {
        cFlags += " -target \(arch)-apple-ios14.0-macabi"
        cFlags += " -iframework \(sdk)/System/iOSSupport/System/Library/Frameworks"
    }

    print("  Compiling tool sources for \(arch)...")

    // Compile each tool source file
    for source in toolSources {
        let sourcePath = "\(patchedSourcePath)/\(source.subdir)/\(source.file)"
        // Use subdir prefix to avoid name collisions (e.g., tar/cmdline.c vs cat/cmdline.c)
        let objName = "\(source.subdir)_\(source.file)".replacingOccurrences(of: ".c", with: ".o")
        // Add the tool's own subdirectory to includes for its headers
        let toolInclude = "-I\(patchedSourcePath)/\(source.subdir)"
        try sh("xcrun --sdk \(platform.sdk) clang -c \(cFlags) \(toolInclude) \(sourcePath) -o \(objDir)/\(objName) -w")
    }

    // Compile globals
    let globalsPath = "\(patchedSourcePath)/\(globalsSource)"
    try sh("xcrun --sdk \(platform.sdk) clang -c \(cFlags) \(globalsPath) -o \(objDir)/libarchive_ios_globals.o -w")
}

// MARK: - Step 3: Link shared dylib

func linkFramework(platform: PlatformConfig, arch: String,
                   sdk: String, iosSystemPath: String,
                   lzmaStaticLib: String?,
                   outputDir: String) throws {
    let versionFlag = minVersionFlag(for: platform, arch: arch)
    let frameworkName = "libarchive_ios"

    let libarchiveA = "\(outputDir)/libarchive_cmake/libarchive/libarchive.a"
    let toolObjDir = "\(outputDir)/tool_obj"

    // Collect all .o files
    let toolObjs = try runAndCapture("ls \(toolObjDir)/*.o 2>/dev/null || true")
    let allObjs = toolObjs
        .split(separator: "\n").map(String.init).filter { !$0.isEmpty }

    let dylibPath = "\(outputDir)/\(frameworkName)"
    var linkCmd = "xcrun --sdk \(platform.sdk) clang -shared -arch \(arch) \(versionFlag)"
    linkCmd += " -isysroot \(sdk)"

    if platform.isCatalyst {
        linkCmd += " -target \(arch)-apple-ios14.0-macabi"
        linkCmd += " -iframework \(sdk)/System/iOSSupport/System/Library/Frameworks"
    }

    linkCmd += " -install_name @rpath/\(frameworkName).framework/\(frameworkName)"
    linkCmd += " -F\(iosSystemPath) -framework ios_system"
    linkCmd += " -lz -lbz2 -liconv"

    // Add all object files
    for obj in allObjs {
        linkCmd += " \(obj)"
    }

    // Force-load libarchive static lib
    linkCmd += " -force_load \(libarchiveA)"

    // Force-load liblzma if available
    if let lzmaLib = lzmaStaticLib {
        linkCmd += " -force_load \(lzmaLib)"
    }

    linkCmd += " -Wl,-dead_strip"
    linkCmd += " -o \(dylibPath)"

    print("  Linking \(frameworkName) dylib for \(arch)...")
    try sh(linkCmd)
}

// MARK: - Framework Bundle Creation

func createFrameworkBundle(
    name: String,
    binaryPath: String,
    platform: PlatformConfig,
    outputDir: String
) throws {
    let frameworkPath = "\(outputDir)/\(name).framework"

    try sh("rm -rf \(frameworkPath)")
    try sh("mkdir -p \(frameworkPath)")

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
            <string>com.libarchive.libarchive-ios</string>
            <key>CFBundleInfoDictionaryVersion</key>
            <string>6.0</string>
            <key>CFBundleName</key>
            <string>\(name)</string>
            <key>CFBundlePackageType</key>
            <string>FMWK</string>
            <key>CFBundleShortVersionString</key>
            <string>3.9.0</string>
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

func createFatBinary(binaries: [(arch: String, path: String)], output: String) throws {
    let inputs = binaries.map { $0.path }.joined(separator: " ")
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

print("libarchive_ios XCFramework Build")
print("================================")
print("")

let buildDir = "\(sourceRoot)/.build"
let frameworkName = "libarchive_ios"

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
    print("  Architectures: \(platform.architectures.joined(separator: ", "))")
    print("  ios_system: \(iosSystemPath)")

    let sdk = try sdkPath(for: platform.sdk)
    let platformBuildDir = "\(buildDir)/\(platform.name)"
    try sh("mkdir -p \(platformBuildDir)")

    var archBinaries: [(arch: String, path: String)] = []

    for arch in platform.architectures {
        let archDir = "\(platformBuildDir)/\(arch)"
        try sh("mkdir -p \(archDir)")

        // Find liblzma if available
        let lzmaInfo = findLiblzma(platform: platform, arch: arch)
        if let lzma = lzmaInfo {
            print("  Found liblzma: \(lzma.staticLib)")
        } else {
            print("  liblzma not found — building without xz/lzma support")
        }

        // 1. Build libarchive static lib via CMake
        try buildLibarchive(platform: platform, arch: arch,
                            sdk: sdk, lzmaInfo: lzmaInfo, outputDir: archDir)
        let cmakeBuildDir = "\(archDir)/libarchive_cmake"

        // 2. Compile patched tool sources
        try compileToolSources(platform: platform, arch: arch,
                               sdk: sdk, cmakeBuildDir: cmakeBuildDir,
                               lzmaHeaders: lzmaInfo?.headers,
                               outputDir: archDir)

        // 3. Link into shared dylib
        try linkFramework(platform: platform, arch: arch,
                          sdk: sdk, iosSystemPath: iosSystemPath,
                          lzmaStaticLib: lzmaInfo?.staticLib,
                          outputDir: archDir)

        archBinaries.append((arch: arch, path: "\(archDir)/\(frameworkName)"))
    }

    // Create fat binary if needed (Catalyst has multiple architectures)
    let finalBinaryPath: String
    if archBinaries.count > 1 {
        print("  Creating fat binary...")
        finalBinaryPath = "\(platformBuildDir)/\(frameworkName)"
        try createFatBinary(binaries: archBinaries, output: finalBinaryPath)
    } else {
        finalBinaryPath = archBinaries[0].path
    }

    // Create framework bundle
    print("  Creating framework bundle...")
    try createFrameworkBundle(name: frameworkName, binaryPath: finalBinaryPath,
                              platform: platform, outputDir: platformBuildDir)

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
    # libarchive_ios XCFramework Release

    ## Checksums

    \(checksums.markdown(headers: "File", "SHA 256"))

    ## Platforms

    - iOS (arm64)
    - iOS Simulator (arm64)
    - Mac Catalyst (arm64, x86_64)
    - visionOS (arm64)
    - visionOS Simulator (arm64)

    ## Build Info

    - libarchive version: 3.9.0
    - Tools: bsdtar, bsdcat, bsdcpio, bsdunzip
    - libarchive built from upstream source via CMake
    - Tool sources patched for __thread + ios_system integration

    """

try write(content: releaseNotes, atPath: "\(buildDir)/release.md")

print("")
print("Build complete!")
print("Output: \(buildDir)/")
print("  - \(frameworkName).xcframework")
print("  - \(frameworkName).xcframework.zip")
print("  - release.md")
