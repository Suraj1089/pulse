// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MemPalette",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MemPalette",
            path: "Sources/MemPalette"
        )
    ]
)
