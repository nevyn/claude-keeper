// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "claude-keeper",
    platforms: [.macOS(.v13)],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1")],
    targets: [
        .executableTarget(
            name: "claude-keeper",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            // Sparkle.framework sits in Contents/Frameworks in the app, and next to the binary under `swift run`.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                                           "-Xlinker", "-rpath", "-Xlinker", "@loader_path"])]),
    ],
    swiftLanguageModes: [.v5]
)
