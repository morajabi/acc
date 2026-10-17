// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Acc",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AccCore", targets: ["AccCore"]),
        .executable(name: "acc", targets: ["AccCLI"]),
        .executable(name: "AccMenuBar", targets: ["AccMenuBar"]),
    ],
    targets: [
        .target(name: "AccCore"),
        .executableTarget(name: "AccCLI", dependencies: ["AccCore"]),
        .executableTarget(name: "AccMenuBar", dependencies: ["AccCore"]),
        .testTarget(name: "AccCoreTests", dependencies: ["AccCore"]),
    ]
)
