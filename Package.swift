// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "mTranslate",
    platforms: [.macOS(.v15)],
    targets: [
        .target(
            name: "mTranslateCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(name: "mTranslate", dependencies: ["mTranslateCore"]),
        .executableTarget(name: "mtprobe", dependencies: ["mTranslateCore"]),
        .testTarget(name: "mTranslateCoreTests", dependencies: ["mTranslateCore"]),
    ]
)
