// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Roost",
    platforms: [.macOS(.v13)],
    dependencies: [
        // SmartClip's clipboard engine, from the SmartClip checkout next to this one.
        .package(path: "../SmartClip/mac"),
    ],
    targets: [
        .target(name: "RoostCore"),
        .executableTarget(name: "Roost", dependencies: [
            "RoostCore",
            .product(name: "SmartClipKit", package: "mac"),
        ]),
        .testTarget(name: "RoostCoreTests", dependencies: ["RoostCore"]),
    ]
)
