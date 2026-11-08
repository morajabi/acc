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
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        .target(name: "AccCore"),
        .executableTarget(name: "AccCLI", dependencies: ["AccCore"]),
        .executableTarget(
            name: "AccMenuBar",
            dependencies: ["AccCore", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "AccCoreTests", dependencies: ["AccCore"]),
    ]
)
