// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Claudes",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "ClaudeTray", targets: ["ClaudeTray"])],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.7.1")
    ],
    targets: [
        .executableTarget(
            name: "ClaudeTray",
            dependencies: ["Sparkle"],
            path: "tray",
            sources: ["main.swift", "UpdateChannel.swift"],
            // Sparkle.framework ships in Contents/Frameworks; without this rpath
            // dyld cannot find it and the app dies before main().
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        )
    ]
)
