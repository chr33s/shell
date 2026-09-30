// curl_ios XCFramework Build Tool
// Usage from curl_ios root: swift run --package-path xcfs build

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
    let opensslSlice: String
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
        opensslSlice: "ios-arm64",
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
        opensslSlice: "ios-arm64-simulator",
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
        opensslSlice: "ios-arm64_x86_64-maccatalyst",
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
        opensslSlice: "xros-arm64",
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
        opensslSlice: "xros-arm64-simulator",
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

func findOpenSSLLibs(for platform: PlatformConfig) -> (ssl: String, crypto: String, includeDir: String)? {
    let sourceRoot = FileManager.default.currentDirectoryPath
    let opensslIosRoot = ProcessInfo.processInfo.environment["OPENSSL_IOS_SOURCE_DIR"]
        ?? URL(fileURLWithPath: sourceRoot)
            .deletingLastPathComponent()
            .appendingPathComponent("openssl_ios")
            .path
    let sslRoot = URL(fileURLWithPath: opensslIosRoot)
        .appendingPathComponent(".build")
        .path

    let sslLib = "\(sslRoot)/libssl.xcframework/\(platform.opensslSlice)/libssl.a"
    let cryptoLib = "\(sslRoot)/libcrypto.xcframework/\(platform.opensslSlice)/libcrypto.a"
    let includeDir = "\(sslRoot)/libssl.xcframework/\(platform.opensslSlice)/Headers"

    guard FileManager.default.fileExists(atPath: sslLib),
          FileManager.default.fileExists(atPath: cryptoLib),
          FileManager.default.fileExists(atPath: includeDir) else {
        return nil
    }

    return (ssl: sslLib, crypto: cryptoLib, includeDir: includeDir)
}

// MARK: - nghttp2 Build

let nghttp2Sources = [
    "nghttp2_pq.c", "nghttp2_map.c", "nghttp2_queue.c", "nghttp2_frame.c",
    "nghttp2_buf.c", "nghttp2_stream.c", "nghttp2_outbound_item.c",
    "nghttp2_session.c", "nghttp2_submit.c", "nghttp2_helper.c",
    "nghttp2_alpn.c", "nghttp2_hd.c", "nghttp2_hd_huffman.c",
    "nghttp2_hd_huffman_data.c", "nghttp2_version.c",
    "nghttp2_priority_spec.c", "nghttp2_option.c", "nghttp2_callbacks.c",
    "nghttp2_mem.c", "nghttp2_http.c", "nghttp2_rcbuf.c",
    "nghttp2_extpri.c", "nghttp2_ratelim.c", "nghttp2_time.c",
    "nghttp2_debug.c", "sfparse.c"
]

func generateNghttp2VersionHeader(sourceRoot: String) throws {
    let templatePath = "\(sourceRoot)/nghttp2/lib/includes/nghttp2/nghttp2ver.h.in"
    let outputPath = "\(sourceRoot)/nghttp2/lib/includes/nghttp2/nghttp2ver.h"

    // nghttp2 version 1.68.90 -> hex 0x01445a
    let version = "1.68.90"
    let versionNum = "0x01445a"

    var template = try String(contentsOfFile: templatePath, encoding: .utf8)
    template = template.replacingOccurrences(of: "@PACKAGE_VERSION@", with: version)
    template = template.replacingOccurrences(of: "@PACKAGE_VERSION_NUM@", with: versionNum)

    try template.write(toFile: outputPath, atomically: true, encoding: .utf8)
    print("  Generated nghttp2ver.h (version \(version))")
}

func buildNghttp2(sourceRoot: String, platform: PlatformConfig, arch: String,
                   sdk: String, outputDir: String) throws {
    let nghttp2LibDir = "\(sourceRoot)/nghttp2/lib"
    let objDir = "\(outputDir)/nghttp2_obj"
    try sh("mkdir -p \(objDir)")

    let versionFlag = minVersionFlag(for: platform, arch: arch)
    let flags = "-DBUILDING_NGHTTP2 -DNGHTTP2_STATICLIB " +
                "-I \(nghttp2LibDir)/includes -I \(nghttp2LibDir) " +
                "-arch \(arch) \(versionFlag) -isysroot \(sdk) -O2 -fembed-bitcode"

    print("  Building nghttp2 for \(arch)...")
    for source in nghttp2Sources {
        let sourcePath = "\(nghttp2LibDir)/\(source)"
        let objName = source.replacingOccurrences(of: ".c", with: ".o")
        try sh("xcrun --sdk \(platform.sdk) clang -c \(flags) \(sourcePath) -o \(objDir)/\(objName)")
    }

    let outputLib = "\(outputDir)/libnghttp2.a"
    let objs = nghttp2Sources.map { "\(objDir)/" + $0.replacingOccurrences(of: ".c", with: ".o") }
        .joined(separator: " ")
    try sh("xcrun --sdk \(platform.sdk) ar rcs \(outputLib) \(objs)")
    print("  Built \(outputLib)")
}

// MARK: - curl CMake Build

func buildCurl(sourceRoot: String, platform: PlatformConfig, arch: String,
               sdk: String, nghttp2Lib: String, opensslLibs: (ssl: String, crypto: String, includeDir: String),
               iosSystemPath: String, outputDir: String) throws {
    let cmakeBuildDir = "\(outputDir)/cmake_build"
    try sh("rm -rf \(cmakeBuildDir)")
    try sh("mkdir -p \(cmakeBuildDir)")

    let nghttp2IncludeDir = "\(sourceRoot)/nghttp2/lib/includes"
    let versionFlag = minVersionFlag(for: platform, arch: arch)

    // Platform-specific CMake flags
    var cmakeCFlags = "-DHAVE_FSETXATTR_6=0 -DHAVE_FSETXATTR_5=0"
    var extraCMakeFlags = ""

    if platform.isCatalyst {
        cmakeCFlags += " -target \(arch)-apple-ios14.0-macabi"
        cmakeCFlags += " -iframework \(sdk)/System/iOSSupport/System/Library/Frameworks"
        extraCMakeFlags += " -DCMAKE_C_COMPILER_TARGET=\(arch)-apple-ios14.0-macabi"
    } else if platform.sdk == "xros" || platform.sdk == "xrsimulator" {
        cmakeCFlags += " \(versionFlag)"
    } else {
        cmakeCFlags += " \(versionFlag)"
    }

    // For simulator, tell CMake it's a simulator
    if platform.sdk == "iphonesimulator" {
        extraCMakeFlags += " -DCMAKE_OSX_SYSROOT=iphonesimulator"
    } else if platform.sdk == "xrsimulator" {
        extraCMakeFlags += " -DCMAKE_OSX_SYSROOT=xrsimulator"
    }

    print("  Configuring curl via CMake for \(platform.name) \(arch)...")
    let cmakeCmd = """
        cmake -B \(cmakeBuildDir) \
          -S \(sourceRoot) \
          -DCMAKE_SYSTEM_NAME=\(platform.cmakeSystemName) \
          -DCMAKE_OSX_ARCHITECTURES=\(arch) \
          -DCMAKE_OSX_DEPLOYMENT_TARGET=\(platform.cmakeDeploymentTarget) \
          -DCMAKE_OSX_SYSROOT=\(sdk) \
          -DBUILD_SHARED_LIBS=OFF \
          -DBUILD_CURL_EXE=OFF \
          -DBUILD_TESTING=OFF \
          -DCURL_USE_OPENSSL=ON \
          -DOPENSSL_SSL_LIBRARY=\(opensslLibs.ssl) \
          -DOPENSSL_CRYPTO_LIBRARY=\(opensslLibs.crypto) \
          -DOPENSSL_INCLUDE_DIR=\(opensslLibs.includeDir) \
          -DUSE_NGHTTP2=ON \
          -DNGHTTP2_INCLUDE_DIR=\(nghttp2IncludeDir) \
          -DNGHTTP2_LIBRARY=\(nghttp2Lib) \
          -DCURL_DISABLE_LDAP=ON \
          -DCURL_DISABLE_LDAPS=ON \
          -DCURL_USE_LIBSSH2=OFF \
          -DCURL_USE_LIBPSL=OFF \
          -DCURL_CA_BUNDLE=none \
          -DCURL_CA_PATH=none \
          -DENABLE_UNIX_SOCKETS=ON \
          -DENABLE_THREADED_RESOLVER=ON \
          -DHAVE_FCNTL_O_NONBLOCK=1 \
          -DHAVE_POSIX_STRERROR_R=1 \
          -DHAVE_CLOCK_GETTIME_MONOTONIC=1 \
          -DHAVE_BUILTIN_AVAILABLE=1 \
          -DHAVE_PIPE2=0 \
          -DCMAKE_C_FLAGS="\(cmakeCFlags)" \
          \(extraCMakeFlags) \
          -G "Unix Makefiles"
        """
    try sh(cmakeCmd)

    print("  Building curl...")
    try sh("cmake --build \(cmakeBuildDir) -j8")
}

// MARK: - curl Tool Source Compilation

let curlToolSources = [
    "config2setopts.c", "slist_wc.c", "terminal.c",
    "tool_cb_dbg.c", "tool_cb_hdr.c", "tool_cb_prg.c",
    "tool_cb_rea.c", "tool_cb_see.c", "tool_cb_soc.c", "tool_cb_wrt.c",
    "tool_cfgable.c", "tool_dirhie.c", "tool_doswin.c", "tool_easysrc.c",
    "tool_filetime.c", "tool_findfile.c", "tool_formparse.c",
    "tool_getparam.c", "tool_getpass.c", "tool_help.c", "tool_helpers.c",
    "tool_ipfs.c", "tool_libinfo.c", "tool_listhelp.c",
    "tool_main.c", "tool_msgs.c", "tool_operate.c", "tool_operhlp.c",
    "tool_paramhlp.c", "tool_parsecfg.c", "tool_progress.c",
    "tool_setopt.c", "tool_ssls.c", "tool_stderr.c",
    "tool_urlglob.c", "tool_util.c", "tool_vms.c",
    "tool_writeout.c", "tool_writeout_json.c", "tool_xattr.c", "var.c"
]

func buildCurlTool(sourceRoot: String, platform: PlatformConfig, arch: String,
                   sdk: String, cmakeBuildDir: String, outputDir: String) throws {
    let toolObjDir = "\(outputDir)/tool_obj"
    try sh("mkdir -p \(toolObjDir)")

    let versionFlag = minVersionFlag(for: platform, arch: arch)

    // Include paths needed by tool source files
    let includePaths = [
        "\(sourceRoot)/src",           // tool_*.h headers
        "\(sourceRoot)/lib",           // curl_setup.h and internal headers
        "\(sourceRoot)/include",       // public curl/*.h headers
        "\(cmakeBuildDir)/lib",        // generated curl_config.h
        "\(cmakeBuildDir)/src",        // generated tool_hugehelp.c
    ]

    let includeFlags = includePaths.map { "-I \($0)" }.joined(separator: " ")

    var cFlags = "-arch \(arch) \(versionFlag) -isysroot \(sdk) -O2"
    cFlags += " \(includeFlags)"
    cFlags += " -DHAVE_CONFIG_H"

    if platform.isCatalyst {
        cFlags += " -target \(arch)-apple-ios14.0-macabi"
        cFlags += " -iframework \(sdk)/System/iOSSupport/System/Library/Frameworks"
    }

    print("  Compiling curl tool sources for \(arch)...")
    for source in curlToolSources {
        let sourcePath = "\(sourceRoot)/src/\(source)"
        let objName = source.replacingOccurrences(of: ".c", with: ".o")
        try sh("xcrun --sdk \(platform.sdk) clang -c \(cFlags) \(sourcePath) -o \(toolObjDir)/\(objName) -w")
    }

    // Also compile files in src/toolx/ subdirectory
    let toolxDir = "\(sourceRoot)/src/toolx"
    if FileManager.default.fileExists(atPath: toolxDir) {
        let toolxFiles = try FileManager.default.contentsOfDirectory(atPath: toolxDir)
            .filter { $0.hasSuffix(".c") }
        for source in toolxFiles {
            let sourcePath = "\(toolxDir)/\(source)"
            let objName = source.replacingOccurrences(of: ".c", with: ".o")
            try sh("xcrun --sdk \(platform.sdk) clang -c \(cFlags) \(sourcePath) -o \(toolObjDir)/\(objName) -w")
        }
    }

    // Also compile the generated tool_hugehelp.c if it exists
    let hugehelpPath = "\(cmakeBuildDir)/src/tool_hugehelp.c"
    if FileManager.default.fileExists(atPath: hugehelpPath) {
        try sh("xcrun --sdk \(platform.sdk) clang -c \(cFlags) \(hugehelpPath) -o \(toolObjDir)/tool_hugehelp.o -w")
    }
}

// MARK: - Framework Linking & Packaging

func linkFramework(sourceRoot: String, platform: PlatformConfig, arch: String,
                   sdk: String, cmakeBuildDir: String, nghttp2Lib: String,
                   opensslLibs: (ssl: String, crypto: String, includeDir: String),
                   iosSystemPath: String, outputDir: String) throws {
    let versionFlag = minVersionFlag(for: platform, arch: arch)
    let frameworkName = "curl_ios"

    let libcurlA = "\(cmakeBuildDir)/lib/libcurl.a"
    let toolObjDir = "\(outputDir)/tool_obj"

    // Collect all tool .o files
    let toolObjs = try runAndCapture("ls \(toolObjDir)/*.o 2>/dev/null || true")
    let toolObjFiles = toolObjs.split(separator: "\n").map(String.init).filter { !$0.isEmpty }

    // Link everything into a shared dylib
    let dylibPath = "\(outputDir)/\(frameworkName)"
    var linkCmd = "xcrun --sdk \(platform.sdk) clang -shared -arch \(arch) \(versionFlag)"
    linkCmd += " -isysroot \(sdk)"

    if platform.isCatalyst {
        linkCmd += " -target \(arch)-apple-ios14.0-macabi"
        linkCmd += " -iframework \(sdk)/System/iOSSupport/System/Library/Frameworks"
    }

    linkCmd += " -install_name @rpath/\(frameworkName).framework/\(frameworkName)"
    linkCmd += " -F\(iosSystemPath) -framework ios_system"
    linkCmd += " -framework Security -framework CoreFoundation"
    linkCmd += " -lz"

    // Add all curl tool object files
    for obj in toolObjFiles {
        linkCmd += " \(obj)"
    }

    // Add static libraries
    linkCmd += " -force_load \(libcurlA)"
    linkCmd += " -force_load \(nghttp2Lib)"
    linkCmd += " -force_load \(opensslLibs.ssl)"
    linkCmd += " -force_load \(opensslLibs.crypto)"

    linkCmd += " -Wl,-dead_strip"
    linkCmd += " -o \(dylibPath)"

    print("  Linking \(frameworkName) dylib for \(arch)...")
    try sh(linkCmd)
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
            <string>com.curl.curl-ios</string>
            <key>CFBundleInfoDictionaryVersion</key>
            <string>6.0</string>
            <key>CFBundleName</key>
            <string>\(name)</string>
            <key>CFBundlePackageType</key>
            <string>FMWK</string>
            <key>CFBundleShortVersionString</key>
            <string>8.22.0</string>
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

print("curl_ios XCFramework Build")
print("==========================")
print("")

let sourceRoot = FileManager.default.currentDirectoryPath
let buildDir = "\(sourceRoot)/.build"
let frameworkName = "curl_ios"

try sh("mkdir -p \(buildDir)")

// Generate nghttp2 version header
print("Generating nghttp2 version header...")
try generateNghttp2VersionHeader(sourceRoot: sourceRoot)

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

    guard let opensslLibs = findOpenSSLLibs(for: platform) else {
        print("Skipping \(platform.name): OpenSSL libraries not found")
        print("  Expected at: ../openssl_ios/.build/libssl.xcframework/\(platform.opensslSlice)/")
        continue
    }

    print("Building for \(platform.name)...")
    print("  SDK: \(platform.sdk)")
    print("  Architectures: \(platform.architectures.joined(separator: ", "))")
    print("  ios_system: \(iosSystemPath)")
    print("  OpenSSL: \(opensslLibs.ssl)")

    let sdk = try sdkPath(for: platform.sdk)
    let platformBuildDir = "\(buildDir)/\(platform.name)"
    try sh("mkdir -p \(platformBuildDir)")

    var archBinaries: [(arch: String, path: String)] = []

    for arch in platform.architectures {
        let archDir = "\(platformBuildDir)/\(arch)"
        try sh("mkdir -p \(archDir)")

        // 1. Build nghttp2 static lib
        try buildNghttp2(sourceRoot: sourceRoot, platform: platform, arch: arch,
                         sdk: sdk, outputDir: archDir)
        let nghttp2Lib = "\(archDir)/libnghttp2.a"

        // 2. Build curl via CMake
        try buildCurl(sourceRoot: sourceRoot, platform: platform, arch: arch,
                      sdk: sdk, nghttp2Lib: nghttp2Lib, opensslLibs: opensslLibs,
                      iosSystemPath: iosSystemPath, outputDir: archDir)

        // 3. Compile curl tool sources
        let cmakeBuildDir = "\(archDir)/cmake_build"
        try buildCurlTool(sourceRoot: sourceRoot, platform: platform, arch: arch,
                          sdk: sdk, cmakeBuildDir: cmakeBuildDir, outputDir: archDir)

        // 4. Link into shared dylib
        try linkFramework(sourceRoot: sourceRoot, platform: platform, arch: arch,
                          sdk: sdk, cmakeBuildDir: cmakeBuildDir, nghttp2Lib: nghttp2Lib,
                          opensslLibs: opensslLibs, iosSystemPath: iosSystemPath,
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
    # curl_ios XCFramework Release

    ## Checksums

    \(checksums.markdown(headers: "File", "SHA 256"))

    ## Platforms

    - iOS (arm64)
    - iOS Simulator (arm64)
    - Mac Catalyst (arm64, x86_64)
    - visionOS (arm64)
    - visionOS Simulator (arm64)

    ## Compatibility

    OpenSSL is compiled with explicit deployment targets for every platform.
    This fixes an illegal-instruction crash when curl initializes OpenSSL on
    older supported iPads, including the A10-based seventh-generation iPad.

    ## Build Info

    - curl version: 8.22.0
    - OpenSSL: 3.5.4
    - nghttp2: 1.68.90
    - HTTP/2 support: yes
    - TLS backend: OpenSSL

    """

try write(content: releaseNotes, atPath: "\(buildDir)/release.md")

print("")
print("Build complete!")
print("Output: \(buildDir)/")
print("  - \(frameworkName).xcframework")
print("  - \(frameworkName).xcframework.zip")
print("  - release.md")
