// swift-tools-version: 6.2
import PackageDescription
import Foundation

// SwiftPM builds every test target before applying --filter. App tests use DEBUG-only seams.
let releaseTestsOnly = ProcessInfo.processInfo.environment["WAFER_RELEASE_TESTS"] == "1"

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
            ],
            swiftSettings: [.treatAllWarnings(as: .error)]
        ),
        .executableTarget(
            name: "WaferApp",
            dependencies: [
                "WaferCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            resources: [
                .copy("Resources/Themes"),
                .copy("Resources/Scripts"),
            ],
            swiftSettings: [.treatAllWarnings(as: .error)],
            linkerSettings: [
                // build-app.sh embeds Sparkle.framework in Contents/Frameworks.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        .executableTarget(
            name: "WaferQuickLook",
            dependencies: ["WaferCore", "WaferQuickLookSupport"],
            exclude: ["Support"],
            swiftSettings: [
                .treatAllWarnings(as: .error),
                .unsafeFlags(["-application-extension"]),
            ],
            linkerSettings: [
                .linkedFramework("QuickLookUI"),
                .unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"]),
            ]
        ),
        .target(
            name: "WaferQuickLookSupport",
            dependencies: ["WaferCore"],
            path: "Sources/WaferQuickLook/Support",
            swiftSettings: [.treatAllWarnings(as: .error)]
        ),
        .testTarget(
            name: "WaferCoreTests",
            dependencies: ["WaferCore"],
            path: "Tests",
            exclude: ["WaferAppTests", "WaferQuickLookTests", "JavaScript", "ReleaseTools"],
            sources: ["WaferCoreTests"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.treatAllWarnings(as: .error)]
        ),
        .testTarget(
            name: "WaferQuickLookTests",
            dependencies: ["WaferCore", "WaferQuickLookSupport"],
            swiftSettings: [.treatAllWarnings(as: .error)]
        ),
    ] + (releaseTestsOnly ? [] : [
        .testTarget(
            name: "WaferAppTests",
            dependencies: ["WaferApp"],
            swiftSettings: [.treatAllWarnings(as: .error)]
        ),
    ])
)
