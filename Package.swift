// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SonoraCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SonoraDSP", targets: ["SonoraDSP"]),
        .library(name: "SonoraProfiles", targets: ["SonoraProfiles"]),
        .library(name: "SonoraPersistence", targets: ["SonoraPersistence"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.3.1"),
    ],
    targets: [
        .target(
            name: "SonoraDSP",
            dependencies: [.product(name: "Atomics", package: "swift-atomics")]
        ),
        .target(name: "SonoraProfiles", dependencies: ["SonoraDSP"]),
        .target(name: "SonoraPersistence", dependencies: ["SonoraProfiles"]),
        .testTarget(name: "SonoraDSPTests", dependencies: ["SonoraDSP"]),
        .testTarget(name: "SonoraProfilesTests", dependencies: ["SonoraProfiles"]),
        .testTarget(name: "SonoraPersistenceTests", dependencies: ["SonoraPersistence"]),
    ]
)
