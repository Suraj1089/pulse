// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Pulse",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Pulse",
            path: "Sources/Pulse",
            // Info.plist is embedded via the linker flag below, not SPM's
            // resource bundling — exclude it from automatic source/resource
            // discovery so it isn't also copied into a resource bundle.
            // The iconset folder is excluded (it's only a build intermediate).
            exclude: ["Resources/Info.plist", "Resources/AppIcon.iconset"],
            resources: [
                .copy("Resources/AppIcon.icns"),
            ],
            // Embeds Info.plist into the built binary so TCC-gated APIs
            // (Apple Events to Chrome, LSUIElement) work from a plain SwiftPM
            // executable, which has no Info.plist otherwise. This is the
            // standard technique for menu-bar-only SwiftPM apps on macOS.
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/Pulse/Resources/Info.plist",
                ])
            ]
        )
    ]
)
