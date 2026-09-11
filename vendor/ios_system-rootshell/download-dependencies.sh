#!/bin/bash

# Script to download openssl and libssh2 XCFrameworks for ios_system

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPS_DIR="$SCRIPT_DIR/Dependencies"

echo "Creating Dependencies directory..."
mkdir -p "$DEPS_DIR"
cd "$DEPS_DIR"

echo ""
echo "Downloading openssl XCFramework..."
if [ ! -d "openssl.xcframework" ]; then
    curl -L -o openssl.xcframework.zip \
        "https://github.com/holzschu/openssl-apple/releases/download/v1.1.1w/openssl-dynamic.xcframework.zip"
    unzip -q openssl.xcframework.zip
    rm openssl.xcframework.zip
    echo "✓ openssl.xcframework downloaded"
else
    echo "✓ openssl.xcframework already exists"
fi

echo ""
echo "Downloading libssh2 XCFramework..."
if [ ! -d "libssh2.xcframework" ]; then
    curl -L -o libssh2.xcframework.zip \
        "https://github.com/holzschu/libssh2-apple/releases/download/v1.11.0/libssh2-dynamic.xcframework.zip"
    unzip -q libssh2.xcframework.zip
    rm libssh2.xcframework.zip
    echo "✓ libssh2.xcframework downloaded"
else
    echo "✓ libssh2.xcframework already exists"
fi

echo ""
echo "✅ Dependencies downloaded successfully!"
echo ""
echo "Location: $DEPS_DIR"
echo ""
echo "Next steps:"
echo "1. Open your Xcode project"
echo "2. Drag both XCFrameworks to your project"
echo "3. Set them to 'Embed & Sign' in your target settings"
echo ""
