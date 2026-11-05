// swift-tools-version: 6.2
import PackageDescription

// Petal for macOS: a dock that replaces macOS's own, with a focus mode for every Desktop and Claude built in.
// macOS 26 and later, for its Liquid Glass. Built into Petal.app by build.sh.
let package = Package(
    name: "Petal",
    platforms: [.macOS(.v26)],
    targets: [.executableTarget(name: "Petal", path: "Sources/Petal")]
)
