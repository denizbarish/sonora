// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SonoraCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SonoraDSP", targets: ["SonoraDSP"]),
    ],
    targets: [
        .target(name: "SonoraDSP"),
        .testTarget(name: "SonoraDSPTests", dependencies: ["SonoraDSP"]),
    ]
)
