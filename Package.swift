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
        .executable(name: "DCSSApp", targets: ["DCSSApp"])
    ],
    targets: [
        .target(
            name: "DCSSCore",
            path: "Sources/DCSSCore"
        ),
        .executableTarget(
            name: "DCSSApp",
            dependencies: ["DCSSCore"],
            path: "Sources/DCSSApp"
        ),
        .testTarget(
            name: "DCSSCoreTests",
            dependencies: ["DCSSCore"],
            path: "Tests/DCSSCoreTests",
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)
