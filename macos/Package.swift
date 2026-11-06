// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HideMyEmail",
    defaultLocalization: "en",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "HideMyEmail", targets: ["HideMyEmail"]),
    ],
    targets: [
        .target(name: "HideMyEmailCore"),
        .executableTarget(
            name: "HideMyEmail",
            dependencies: ["HideMyEmailCore"]
        ),
        .testTarget(
            name: "HideMyEmailCoreTests",
            dependencies: ["HideMyEmailCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
