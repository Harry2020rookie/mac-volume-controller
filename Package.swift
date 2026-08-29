// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PerAppVolume",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "PerAppVolume",
            path: "Sources/PerAppVolume"
        )
    ]
)
