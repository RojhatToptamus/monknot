// swift-tools-version:5.3

import PackageDescription

let package = Package(
    name: "monknot",
    platforms: [
        .macOS("14.0")
    ],
    products: [
        .executable(name: "monknot", targets: ["Monknot"])
    ],
    targets: [
        .target(
            name: "MonknotCore",
            resources: [.process("Resources")]
        ),
        .target(
            name: "Monknot",
            dependencies: ["MonknotCore"],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "MonknotTests",
            dependencies: ["MonknotCore"]
        )
    ]
)
