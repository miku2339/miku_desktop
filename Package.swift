// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MikuDesktop",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "MikuDesktop", targets: ["MikuDesktop"])
    ],
    targets: [
        .executableTarget(
            name: "MikuDesktop",
            path: "Sources/MikuDesktop"
        )
    ],
    swiftLanguageVersions: [.v5]
)
