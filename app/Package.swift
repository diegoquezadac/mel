// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "mel-app",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "mel-app", path: "Sources"),
    ],
    swiftLanguageModes: [.v5]
)
