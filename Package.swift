// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "DirCompare",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DirCompare", targets: ["DirCompare"]),
        .executable(name: "dircmp", targets: ["dircmp"]),
        .library(name: "DirCompareCore", targets: ["DirCompareCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.6.0"),
    ],
    targets: [
        // Scanning and comparison logic. No UI, so it can be unit tested.
        .target(name: "DirCompareCore"),
        // The SwiftUI app.
        .executableTarget(
            name: "DirCompare",
            dependencies: ["DirCompareCore"]
        ),
        // The command-line tool. Not "dircompare": that would clash with
        // "DirCompare" in .build on a case-insensitive volume.
        .executableTarget(
            name: "dircmp",
            dependencies: [
                "DirCompareCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "DirCompareCoreTests",
            dependencies: ["DirCompareCore"]
        ),
    ]
)
