// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StockerMac",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "StockerMac", targets: ["StockerMac"])
    ],
    targets: [
        .executableTarget(
            name: "StockerMac",
            path: "Sources/StockerMac",
            resources: [.process("Resources")]
        )
    ]
)
