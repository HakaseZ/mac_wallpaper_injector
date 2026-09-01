// code-review-marker
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MWIPanel",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MWIPanel",
            path: "Sources/MWIPanel"
        )
    ]
)
