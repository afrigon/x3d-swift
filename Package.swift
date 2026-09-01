// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "XEngine",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
        .tvOS(.v18),
        .watchOS(.v11),
        .visionOS(.v2)
    ],
    products: [
        .library(name: "XEngineCore", targets: ["XEngineCore"]),
        .library(name: "XEngineMetal", targets: ["XEngineMetal"]),
        .library(name: "XEngineLoader", targets: ["XEngineLoader"])
    ],
    targets: [
        .target(
            name: "XEngineCore",
            path: "Sources/Core"
        ),
        .target(
            name: "XEngineLoader",
            dependencies: [
                .target(name: "XEngineCore")
            ],
            path: "Sources/Loader"
        ),
        .target(
            name: "XEngineMetal",
            dependencies: [
                .target(name: "XEngineCore")
            ],
            path: "Sources/Metal",
            resources: [
                .process("Resources/Shaders")
            ]
        ),
        .testTarget(
            name: "XEngineCoreTests",
            dependencies: [
                "XEngineCore"
            ],
            path: "Tests/Core"
        )
    ]
)
