// swift-tools-version:5.9
// The Mac app for the audiobook tools. Build the .app with ./build.sh (no Xcode project needed).
import PackageDescription

let package = Package(
    name: "AudiobookMaker",
    platforms: [.macOS(.v13)],  // Ventura and newer
    targets: [
        .executableTarget(name: "AudiobookMaker", path: "Sources/AudiobookMaker")
    ]
)
