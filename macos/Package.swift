// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HideMyEmail",
    defaultLocalization: "en",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "HideMyEmail", targets: ["HideMyEmail"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .target(name: "HideMyEmailCore"),
        .executableTarget(
            name: "HideMyEmail",
            dependencies: ["HideMyEmailCore", .product(name: "Sparkle", package: "Sparkle")]
        ),
        .testTarget(
            name: "HideMyEmailCoreTests",
            dependencies: ["HideMyEmailCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
