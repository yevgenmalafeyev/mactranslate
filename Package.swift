// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MacTranslate",
    platforms: [.macOS(.v15)],
    targets: [
        .target(
            name: "MacTranslateCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(name: "MacTranslate", dependencies: ["MacTranslateCore"]),
        .executableTarget(name: "mtprobe", dependencies: ["MacTranslateCore"]),
        .testTarget(name: "MacTranslateCoreTests", dependencies: ["MacTranslateCore"]),
    ]
)
