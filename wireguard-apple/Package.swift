// swift-tools-version:5.5
import PackageDescription
import Foundation

let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let libDir = "\(packageDir)/Sources/WireGuardKitGo/out"
let libDirMacOS = "\(packageDir)/Sources/WireGuardKitGo/out-macos"

let package = Package(
    name: "WireGuardKit",
    platforms: [
        .macOS(.v12),
        .iOS(.v15)
    ],
    products: [
        .library(name: "WireGuardKit", targets: ["WireGuardKit"])
    ],
    targets: [
        .target(
            name: "WireGuardKit",
            dependencies: ["WireGuardKitGo", "WireGuardKitC"]
        ),
        .target(
            name: "WireGuardKitC",
            dependencies: [],
            publicHeadersPath: "."
        ),
        .target(
            name: "WireGuardKitGo",
            dependencies: [],
            exclude: [
                "goruntime-boottime-over-monotonic.diff",
                "go.mod",
                "go.sum",
                "api-apple.go",
                "Makefile",
                "out",
                "out-macos",
            ],
            publicHeadersPath: ".",
            linkerSettings: [
                .unsafeFlags(["-L", libDir], .when(platforms: [.iOS])),
                .unsafeFlags(["-L", libDirMacOS], .when(platforms: [.macOS])),
                .linkedLibrary("wg-go"),
                .linkedLibrary("resolv")
            ]
        )
    ]
)
