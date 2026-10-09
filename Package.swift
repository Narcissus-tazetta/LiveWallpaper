// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

import Foundation
import PackageDescription

let minimumMacOSVersion = "13.0"

/// Version of the macOS SDK the active toolchain links against, read from its SDKSettings.json.
/// The swiftbuild build system records the deployment target as the SDK version in the binary,
/// and macOS then draws the app with the controls of that old SDK (no Liquid Glass). Telling the
/// linker the real version keeps `swift build` / `swift run` looking like the shipped app.
func activeMacOSSDKVersion() -> String? {
    let environment = Context.environment
    var sdkCandidates: [String] = []
    if let sdkRoot = environment["SDKROOT"], sdkRoot.hasPrefix("/") {
        sdkCandidates.append(sdkRoot)
    }
    var developerDirs: [String] = []
    if let developerDir = environment["DEVELOPER_DIR"] {
        developerDirs.append(developerDir)
    }
    if let selected = try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link") {
        developerDirs.append(selected)
    }
    for developerDir in developerDirs {
        sdkCandidates.append("\(developerDir)/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk")
        sdkCandidates.append("\(developerDir)/SDKs/MacOSX.sdk")
    }
    sdkCandidates.append("/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk")

    for sdk in sdkCandidates {
        guard let data = FileManager.default.contents(atPath: "\(sdk)/SDKSettings.json"),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = settings["Version"] as? String
        else {
            continue
        }
        return version
    }
    return nil
}

// The swiftbuild build system copies Sparkle.framework next to the executable but, unlike the
// native one, adds no rpath to find it.
var linkerFlags = ["-Xlinker", "-rpath", "-Xlinker", "@executable_path"]
if let sdkVersion = activeMacOSSDKVersion() {
    linkerFlags += ["-Xlinker", "-platform_version", "-Xlinker", "macos",
                    "-Xlinker", minimumMacOSVersion, "-Xlinker", sdkVersion]
}

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
            linkerSettings: [
                .unsafeFlags(linkerFlags)
            ]
        ),
        .testTarget(
            name: "LiveWallpaperTests",
            dependencies: ["LiveWallpaper"]
        )
    ]
)
