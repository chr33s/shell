# Building ios_system XCFrameworks

This document describes how to rebuild all ios_system xcframeworks with visionOS support.

## Prerequisites

1. Xcode 26+ with visionOS SDK support
2. OpenSSL built with deprecated API support (see below)
3. libssh2-for-iOS repository at `../libssh2-for-iOS`

## Building OpenSSL with Deprecated API

The SSH frameworks require OpenSSL's deprecated low-level APIs (RSA, DSA, EC_KEY types).
By default, OpenSSL 3.x builds with `no-deprecated` which removes these APIs.

```bash
cd /Users/kit/Development/libssh2-for-iOS

# Build OpenSSL with deprecated API enabled
./openssl/build-all.sh --deprecated

# Create combined openssl.xcframework (libssl + libcrypto merged)
# This avoids duplicate header conflicts in Xcode

# Create temp directories for combined libraries
mkdir -p tmp_combined/{ios-arm64,ios-arm64-simulator,ios-arm64_x86_64-maccatalyst,xros-arm64,xros-arm64-simulator}/lib

# Merge static libraries for each platform
libtool -static bin/iPhoneOS26.1-arm64.sdk/lib/libssl.a bin/iPhoneOS26.1-arm64.sdk/lib/libcrypto.a \
    -o tmp_combined/ios-arm64/lib/libcrypto.a

libtool -static bin/iPhoneSimulator26.1-arm64.sdk/lib/libssl.a bin/iPhoneSimulator26.1-arm64.sdk/lib/libcrypto.a \
    -o tmp_combined/ios-arm64-simulator/lib/libcrypto.a

libtool -static bin/MacOSX15.2-arm64.sdk/lib/libssl.a bin/MacOSX15.2-arm64.sdk/lib/libcrypto.a \
    -o tmp_combined/ios-arm64_x86_64-maccatalyst/lib/libcrypto.a

libtool -static bin/XROS26.1-arm64.sdk/lib/libssl.a bin/XROS26.1-arm64.sdk/lib/libcrypto.a \
    -o tmp_combined/xros-arm64/lib/libcrypto.a

libtool -static bin/XRSimulator26.1-arm64.sdk/lib/libssl.a bin/XRSimulator26.1-arm64.sdk/lib/libcrypto.a \
    -o tmp_combined/xros-arm64-simulator/lib/libcrypto.a

# Copy headers (use any platform's headers, they're identical)
mkdir -p tmp_headers
cp -R bin/iPhoneOS26.1-arm64.sdk/include/openssl tmp_headers/

# Create combined xcframework
rm -rf openssl.xcframework
xcodebuild -create-xcframework \
    -library tmp_combined/ios-arm64/lib/libcrypto.a -headers tmp_headers \
    -library tmp_combined/ios-arm64-simulator/lib/libcrypto.a -headers tmp_headers \
    -library tmp_combined/ios-arm64_x86_64-maccatalyst/lib/libcrypto.a -headers tmp_headers \
    -library tmp_combined/xros-arm64/lib/libcrypto.a -headers tmp_headers \
    -library tmp_combined/xros-arm64-simulator/lib/libcrypto.a -headers tmp_headers \
    -output openssl.xcframework

# Cleanup
rm -rf tmp_combined tmp_headers
```

## ios_system Project Configuration

The project references `openssl.xcframework` from `../libssh2-for-iOS/openssl.xcframework`.

Key project file changes (already applied):
- `ios_system.xcodeproj/project.pbxproj`: Updated to use combined `openssl.xcframework` instead of separate libssl/libcrypto

## Building All XCFrameworks

```bash
cd /Users/kit/Development/ios_system

# Build all frameworks (ios_system, awk, curl_ios, files, shell, ssh_cmd, ssh_cmdA, ssh_agent, sshd, tar, text)
swift run --package-path xcfs build

# Or build specific frameworks:
swift run --package-path xcfs build ssh_cmd,ssh_cmdA,ssh_agent
```

## Build Output

XCFrameworks are created in `.build/<scheme>/<scheme>.xcframework`:
- `.build/ios_system/ios_system.xcframework`
- `.build/ssh_cmd/ssh_cmd.xcframework`
- `.build/ssh_cmdA/ssh_cmdA.xcframework`
- `.build/ssh_agent/ssh_agent.xcframework`
- etc.

Each xcframework includes slices for:
- `ios-arm64` (iPhone/iPad device)
- `ios-arm64-simulator` (Simulator on Apple Silicon)
- `ios-arm64_x86_64-maccatalyst` (Mac Catalyst)
- `xros-arm64` (visionOS device)
- `xros-arm64-simulator` (visionOS Simulator)

## ghostty-ios Integration

The ghostty-ios project references frameworks directly from the ios_system build directory.
After rebuilding, the frameworks are automatically available to ghostty-ios.

Framework paths referenced in ghostty-ios:
- `../ios_system/.build/ios_system/ios_system.xcframework`
- `../ios_system/.build/ssh_cmd/ssh_cmd.xcframework`
- etc.

## Troubleshooting

### "framework 'ios_system' not found" during visionOS builds

The build script pre-builds ios_system for visionOS platforms to populate DerivedData.
If this fails, manually build ios_system first:

```bash
xcodebuild build -project ios_system.xcodeproj -scheme ios_system -sdk xros \
    -configuration Release EXCLUDED_ARCHS=x86_64

xcodebuild build -project ios_system.xcodeproj -scheme ios_system -sdk xrsimulator \
    -configuration Release EXCLUDED_ARCHS=x86_64
```

### Duplicate symbol errors (RSA_sign, RSA_verify, BN_is_prime_ex)

These errors occur when OpenSSL is built with deprecated API enabled but `openssl-compat.c`
still defines compatibility functions. The fix is applied in `ssh_keygen/openbsd-compat/openssl-compat.c`:

The RSA/BN wrapper functions are now wrapped with `#ifdef OPENSSL_NO_DEPRECATED_3_0` so they
only compile when the deprecated API is NOT available from OpenSSL.

### visionOS Simulator archive builds for wrong platform

Use explicit `SDKROOT` and `SUPPORTED_PLATFORMS` settings:

```bash
xcodebuild archive -project ios_system.xcodeproj -scheme <scheme> -sdk xrsimulator \
    ... SDKROOT=xrsimulator SUPPORTED_PLATFORMS=xrsimulator ...
```

This is handled automatically by the xcfs build script.
