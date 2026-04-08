#!/bin/bash
# Build AmneziaWG Go static library for iOS (device + simulator).
# Run on Mac with Xcode + Go (1.21+) installed.
# Output: wireguard-apple/Sources/WireGuardKitGo/out/libwg-go.a  (device, used by Xcode Cloud)
#         wireguard-apple/Frameworks/WireGuardKitGo.xcframework/  (both slices, for reference)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WG_DIR="$SCRIPT_DIR/wireguard-apple/Sources/WireGuardKitGo"
XCF_DIR="$SCRIPT_DIR/wireguard-apple/Frameworks/WireGuardKitGo.xcframework"

echo "==> Resolving amneziawg-go dependencies"
cd "$WG_DIR"
go mod tidy

echo "==> Building for iOS device (arm64)"
PLATFORM_NAME=iphoneos \
ARCHS=arm64 \
DEPLOYMENT_TARGET_CLANG_FLAG_NAME=miphoneos-version-min \
DEPLOYMENT_TARGET_CLANG_ENV_NAME=IPHONEOS_DEPLOYMENT_TARGET \
IPHONEOS_DEPLOYMENT_TARGET=16.0 \
make build

cp out/libwg-go.a out/libwg-go-arm64-device.a
echo "   device arm64: $(wc -c < out/libwg-go-arm64-device.a) bytes"

echo "==> Building for iOS simulator (arm64)"
PLATFORM_NAME=iphonesimulator \
ARCHS=arm64 \
DEPLOYMENT_TARGET_CLANG_FLAG_NAME=miphonesimulator-version-min \
DEPLOYMENT_TARGET_CLANG_ENV_NAME=IPHONESIMULATOR_DEPLOYMENT_TARGET \
IPHONESIMULATOR_DEPLOYMENT_TARGET=16.0 \
make build

cp out/libwg-go.a out/libwg-go-arm64-sim.a
echo "   simulator arm64: $(wc -c < out/libwg-go-arm64-sim.a) bytes"

echo "==> Restoring device binary as out/libwg-go.a (used by Xcode Cloud SPM)"
cp out/libwg-go-arm64-device.a out/libwg-go.a

echo "==> Updating xcframework slices"
cp out/libwg-go-arm64-device.a "$XCF_DIR/ios-arm64/libwg-go.a"
ls "$XCF_DIR/ios-arm64-simulator/" && cp out/libwg-go-arm64-sim.a "$XCF_DIR/ios-arm64-simulator/libwg-go.a" || true

echo "==> Done. Stage and commit:"
echo "    git add wireguard-apple/Sources/WireGuardKitGo/out/libwg-go.a"
echo "    git add wireguard-apple/Frameworks/WireGuardKitGo.xcframework/"
echo "    git add wireguard-apple/Sources/WireGuardKitGo/{api-apple.go,go.mod,go.sum,wireguard.h}"
echo "    git add WireGuardTunnel/PacketTunnelProvider.swift"
