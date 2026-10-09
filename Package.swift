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
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.10.0")
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
            ],
            // The swiftbuild build system copies Sparkle.framework next to the
            // executable but, unlike the native one, adds no rpath to find it.
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path"])
            ]
        ),
        .testTarget(
            name: "LiveWallpaperTests",
            dependencies: ["LiveWallpaper"]
        )
    ]
)
