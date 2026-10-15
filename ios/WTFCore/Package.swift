// swift-tools-version:5.9
import PackageDescription

// WTF's logic with no Apple-only frameworks: dates, list rules, the instant recap, recording
// rules and prompts. It builds and is tested on Linux too (`swift test`), so most of it is
// checked before a Mac ever sees it.
let package = Package(
    name: "WTFCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "WTFCore", targets: ["WTFCore"])],
    targets: [
        .target(name: "WTFCore"),
        .testTarget(name: "WTFCoreTests", dependencies: ["WTFCore"]),
    ]
)
