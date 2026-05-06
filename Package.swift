// swift-tools-version:5.0

import PackageDescription

let package = Package(
    name: "Markprev",
    platforms: [
        .macOS("14.0")
    ],
    products: [
        .executable(name: "Markprev", targets: ["Markprev"])
    ],
    targets: [
        .target(name: "MarkprevCore"),
        .target(
            name: "Markprev",
            dependencies: ["MarkprevCore"]
        ),
        .testTarget(
            name: "MarkprevTests",
            dependencies: ["MarkprevCore"]
        )
    ]
)
