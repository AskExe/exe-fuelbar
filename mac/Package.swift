// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ExeFuelbarMenubar",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ExeFuelbarMenubar", targets: ["ExeFuelbarMenubar"])
    ],
    targets: [
        .executableTarget(
            name: "ExeFuelbarMenubar",
            path: "Sources/ExeFuelbarMenubar",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "ExeFuelbarMenubarTests",
            dependencies: ["ExeFuelbarMenubar"],
            path: "Tests/ExeFuelbarMenubarTests"
        )
    ]
)
