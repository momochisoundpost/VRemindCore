// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VRemindCore",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "VRemindCore",
            targets: ["VRemindCore"]
        ),
    ],
    targets: [
        .target(
            name: "VRemindCore"
        ),
        .testTarget(
            name: "VRemindCoreTests",
            dependencies: ["VRemindCore"]
        ),
    ]
)
