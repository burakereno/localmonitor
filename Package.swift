// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "LocalMonitor",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "LocalMonitor", targets: ["LocalMonitor"])
    ],
    targets: [
        .executableTarget(
            name: "LocalMonitor",
            path: "Sources/LocalMonitor",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "LocalMonitorTests",
            dependencies: ["LocalMonitor"],
            path: "Tests/LocalMonitorTests"
        )
    ]
)
