// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "StemMixer",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "StemMixer", path: "Sources/StemMixer")
    ]
)
