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
    targets: [
        .target(name: "SonoraDSP"),
        .testTarget(name: "SonoraDSPTests", dependencies: ["SonoraDSP"]),
        .target(name: "SonoraProfiles", dependencies: ["SonoraDSP"]),
        .testTarget(name: "SonoraProfilesTests", dependencies: ["SonoraProfiles"]),
        .target(name: "SonoraPersistence", dependencies: ["SonoraProfiles"]),
        .testTarget(name: "SonoraPersistenceTests", dependencies: ["SonoraPersistence"]),
    ]
)
