// swift-tools-version: 5.9
// Package.swift
//
// Declares the WireGuardKit dependency.
// In Xcode: File > Add Package Dependencies > paste the URL below.
// After adding, link WireGuardKit to the WireGuardTunnel target ONLY
// (it must not be linked to the main app target).
//
// URL: https://github.com/WireGuard/wireguard-apple
// Minimum version: 1.0.15-26

import PackageDescription

let package = Package(
    name: "WraithVPN",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    dependencies: [
        .package(
            url: "https://github.com/WireGuard/wireguard-apple",
            from: "1.0.15-26"
        ),
    ],
    targets: [
        // This manifest is informational only for developers cloning the repo.
        // The actual linking is done inside the .xcodeproj.
        .target(
            name: "WraithVPNPlaceholder",
            dependencies: []
        ),
    ]
)
