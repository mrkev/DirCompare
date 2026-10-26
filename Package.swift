// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "DirCompare",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DirCompare", targets: ["DirCompare"]),
        .library(name: "DirCompareCore", targets: ["DirCompareCore"]),
    ],
    targets: [
        // Scanning and comparison logic. No UI, so it can be unit tested.
        .target(name: "DirCompareCore"),
        // The SwiftUI app.
        .executableTarget(
            name: "DirCompare",
            dependencies: ["DirCompareCore"]
        ),
        .testTarget(
            name: "DirCompareCoreTests",
            dependencies: ["DirCompareCore"]
        ),
    ]
)
