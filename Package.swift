// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "LiveWallpaper",
    defaultLocalization: "ja",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "LiveWallpaper",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/LiveWallpaper",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "LiveWallpaperTests",
            dependencies: ["LiveWallpaper"]
        )
    ]
)
