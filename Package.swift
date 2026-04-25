// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "VoxUpdates",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "VoxUpdatesToolHost", targets: ["VoxUpdatesToolHost"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.1")
    ],
    targets: [
        .executableTarget(
            name: "VoxUpdatesToolHost",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ]
        )
    ]
)
