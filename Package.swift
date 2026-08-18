// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StockerMac",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "StockerCore", targets: ["StockerCore"]),
        .executable(name: "StockerMac", targets: ["StockerMac"])
    ],
    targets: [
        .target(
            name: "StockerCore",
            path: "Sources/StockerCore"
        ),
        .executableTarget(
            name: "StockerMac",
            dependencies: ["StockerCore"],
            path: "Sources/StockerMac",
            resources: [.process("Resources")]
        ),
    ]
)
