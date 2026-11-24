// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "KeyVeil",
    defaultLocalization: "en",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "KeyVeil", targets: ["HideMyEmail"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .binaryTarget(
            name: "llama",
            path: "Frameworks/llama.xcframework"
        ),
        .target(name: "HideMyEmailCore"),
        .target(
            name: "LayoutSwitcherCore",
            resources: [.process("Resources")]
        ),
        .target(
            name: "AutocompleteCore",
            dependencies: ["llama"]
        ),
        .target(
            name: "DuoCore",
            path: "Sources/DuoCore"
        ),
        .target(
            name: "LidAngle",
            path: "Sources/LidAngle"
        ),
        .target(
            name: "DuoRender",
            dependencies: ["DuoCore"],
            path: "Sources/DuoRender"
        ),
        .target(
            name: "SnowpileCore",
            path: "Sources/SnowpileCore"
        ),
        .executableTarget(
            name: "HideMyEmail",
            dependencies: [
                "HideMyEmailCore",
                "LayoutSwitcherCore",
                "AutocompleteCore",
                "DuoCore",
                "LidAngle",
                "DuoRender",
                "SnowpileCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ]
        ),
        .testTarget(
            name: "HideMyEmailCoreTests",
            dependencies: ["HideMyEmailCore"]
        ),
        .testTarget(
            name: "LayoutSwitcherCoreTests",
            dependencies: ["LayoutSwitcherCore"]
        ),
        .testTarget(
            name: "AutocompleteCoreTests",
            dependencies: ["AutocompleteCore"]
        ),
        .testTarget(
            name: "DuoCoreTests",
            dependencies: ["DuoCore"]
        ),
        .testTarget(
            name: "SnowpileCoreTests",
            dependencies: ["SnowpileCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
