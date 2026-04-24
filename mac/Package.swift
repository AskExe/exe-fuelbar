// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodeBurnMenubar",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "CodeBurnMenubar", targets: ["CodeBurnMenubar"])
    ],
    targets: [
        .executableTarget(
            name: "CodeBurnMenubar",
            path: "Sources/CodeBurnMenubar",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "CodeBurnMenubarTests",
            dependencies: ["CodeBurnMenubar"],
            path: "Tests/CodeBurnMenubarTests"
        )
    ]
)
