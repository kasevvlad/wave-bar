// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WaveBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "WaveBar", path: "Sources/WaveBar")
    ]
)
