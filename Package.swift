// swift-tools-version:5.4

import PackageDescription

let package = Package(
    name: "monknot",
    platforms: [
        .macOS("14.0")
    ],
    products: [
        .executable(name: "monknot-capture", targets: ["MonknotCapture"]),
        .executable(name: "monknot-export", targets: ["MonknotExport"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/sparkle-project/Sparkle",
            .exact("2.9.5")
        )
    ],
    targets: [
        .target(
            name: "MonknotCore",
            resources: [.process("Resources")]
        ),
        .target(
            name: "MonknotApp",
            dependencies: [
                "MonknotCore",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/Monknot",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "MonknotTests",
            dependencies: ["MonknotCore"]
        ),
        .testTarget(
            name: "MonknotAppTests",
            dependencies: [
                "MonknotApp",
                .product(name: "Sparkle", package: "Sparkle")
            ]
        ),
        .executableTarget(
            name: "MonknotSmokeTests",
            dependencies: ["MonknotCore"],
            path: "Tests/MonknotSmokeTests"
        ),
        .executableTarget(
            name: "MonknotStoreSmokeTests",
            dependencies: ["MonknotApp"],
            path: "Tests/MonknotStoreSmokeTests",
            sources: [
                "MonknotStoreSmokeTestsSupport.swift",
                "MonknotStoreSmokeTests.swift"
            ]
        ),
        .executableTarget(
            name: "MonknotRecentWorkspaceSmokeTests",
            dependencies: ["MonknotCore"],
            path: "Tests/MonknotRecentWorkspaceSmokeTests"
        ),
        .executableTarget(
            name: "MonknotShortcutSmokeTests",
            dependencies: ["MonknotCore"],
            path: "Tests/MonknotShortcutSmokeTests"
        ),
        .executableTarget(
            name: "MonknotExport",
            dependencies: ["MonknotCore"],
            path: "Sources/MonknotExport"
        ),
        .executableTarget(
            name: "MonknotCapture",
            dependencies: ["MonknotCore"],
            path: "Sources/MonknotCapture"
        ),
        .executableTarget(
            name: "MonknotThemeCatalogExport",
            dependencies: ["MonknotCore"],
            path: "Sources/MonknotThemeCatalogExport"
        ),
        .executableTarget(
            name: "MonknotWorkspaceExport",
            dependencies: ["MonknotCore"],
            path: "Tests/MonknotWorkspaceExport"
        )
    ]
)
