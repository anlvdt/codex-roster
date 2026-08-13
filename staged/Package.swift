// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexRoster",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CodexRoster", targets: ["CodexRoster"]),
    ],
    targets: [
        .executableTarget(
            name: "CodexRoster",
            path: "Sources/NextAccount"
        ),
    ]
)
