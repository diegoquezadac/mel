// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "mel-capture",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "mel-capture", path: "Sources"),
    ],
    swiftLanguageModes: [.v5]
)
