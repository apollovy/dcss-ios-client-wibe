// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DCSSiOSClient",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "DCSSCore", targets: ["DCSSCore"]),
        .library(name: "DCSSCoreFFI", targets: ["DCSSCoreFFI"]),
        .executable(name: "DCSSApp", targets: ["DCSSApp"])
    ],
    targets: [
        .target(
            name: "DCSSCore",
            path: "Sources/DCSSCore"
        ),
        .target(
            name: "DCSSCoreFFI",
            dependencies: ["DCSSCore"],
            path: "Sources/DCSSCoreFFI"
        ),
        .executableTarget(
            name: "DCSSApp",
            dependencies: ["DCSSCore", "DCSSCoreFFI"],
            path: "Sources/DCSSApp"
        ),
        .testTarget(
            name: "DCSSCoreTests",
            dependencies: ["DCSSCore", "DCSSCoreFFI"],
            path: "Tests/DCSSCoreTests",
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)
