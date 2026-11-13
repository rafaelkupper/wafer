// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Wafer",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "WaferCore", targets: ["WaferCore"]),
        .executable(name: "Wafer", targets: ["WaferApp"]),
        .executable(name: "WaferQuickLook", targets: ["WaferQuickLook"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.7.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        .target(
            name: "WaferCore",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
            ],
            resources: [
                .process("Resources"),
            ]
        ),
        .executableTarget(
            name: "WaferApp",
            dependencies: [
                "WaferCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            resources: [
                .copy("Resources/Themes"),
            ],
            linkerSettings: [
                // build-app.sh embeds Sparkle.framework in Contents/Frameworks.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        .executableTarget(
            name: "WaferQuickLook",
            dependencies: ["WaferCore"],
            swiftSettings: [
                .unsafeFlags(["-application-extension"]),
            ],
            linkerSettings: [
                .linkedFramework("QuickLookUI"),
                .unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"]),
            ]
        ),
        .testTarget(
            name: "WaferCoreTests",
            dependencies: ["WaferCore"]
        ),
        .testTarget(
            name: "WaferAppTests",
            dependencies: ["WaferApp"]
        ),
    ]
)
