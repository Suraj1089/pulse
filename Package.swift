// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Pulse",
    platforms: [.macOS(.v14)],
    dependencies: [
        // The only dependency: a VT100/xterm emulator for the integrated
        // terminal. It is created lazily, so it costs nothing until the
        // terminal is first opened. Pinned: 1.19+ needs swift-tools 6.x.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.18.0"),
    ],
    targets: [
        .executableTarget(
            name: "Pulse",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "Sources/Pulse",
            // Info.plist is embedded via the linker flag below and the icon is
            // copied by scripts/bundle.sh, so SwiftPM generates no resource
            // bundle. The iconset folder is a build intermediate.
            exclude: ["Resources"],
            // Embeds Info.plist into the binary so `swift run` behaves like
            // the bundled app (bundle id, document types, display name).
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/Pulse/Resources/Info.plist",
                ])
            ]
        ),
        // End-to-end tests: they drive the real window controller, editor,
        // sidebar and palette in-process against temporary fixture folders.
        .testTarget(
            name: "PulseTests",
            dependencies: ["Pulse"],
            path: "Tests/PulseTests"
        ),
    ]
)
