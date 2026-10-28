// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "claude-keeper",
    platforms: [.macOS(.v13)],
    targets: [.executableTarget(name: "claude-keeper")],
    swiftLanguageModes: [.v5]
)
