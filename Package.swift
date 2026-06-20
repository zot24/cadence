// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Cadence",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        // Foundation-only shared core: models, SQLite store, job-source parsers.
        // Deliberately free of SwiftUI so the recorder shim can link it too.
        .target(
            name: "CadenceCore",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        // The recorder shim. Wraps an adopted job's command, captures
        // stdout/stderr + timing + exit code into the run-history database.
        .executableTarget(
            name: "cadence-rec",
            dependencies: ["CadenceCore"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        // The SwiftUI menu-bar app.
        .executableTarget(
            name: "Cadence",
            dependencies: ["CadenceCore"],
            // The icon is bundled into Cadence.app by scripts/build_app.sh, not by SwiftPM.
            exclude: ["Resources/AppIcon.icns"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "CadenceCoreTests",
            dependencies: ["CadenceCore"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
    ]
)
