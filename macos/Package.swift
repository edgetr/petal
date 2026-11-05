// swift-tools-version: 6.2
import PackageDescription

// Petal for macOS: a dock that replaces macOS's own, with a focus mode for every Desktop and Claude built in.
// macOS 26 and later, for its Liquid Glass. Built into Petal.app by build.sh.
let package = Package(
    name: "Petal",
    platforms: [.macOS(.v26)],
    targets: [.executableTarget(name: "Petal", path: "Sources/Petal")],
    // Swift 5 language mode, as Sayzen: AppKit's callbacks make Swift 6's strict concurrency checks mostly noise.
    swiftLanguageModes: [.v5]
)
