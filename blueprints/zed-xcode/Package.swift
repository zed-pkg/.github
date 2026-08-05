// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ZedCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ZedCore", targets: ["ZedCore"])
    ],
    targets: [
        .target(name: "ZedCore"),
        .testTarget(name: "ZedCoreTests", dependencies: ["ZedCore"])
    ]
)
