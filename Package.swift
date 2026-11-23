// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DesktopCats",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DesktopCats", targets: ["DesktopCats"]),
        .library(name: "DesktopCatsCore", targets: ["DesktopCatsCore"])
    ],
    targets: [
        .target(name: "DesktopCatsCore"),
        .executableTarget(
            name: "DesktopCats",
            dependencies: ["DesktopCatsCore"],
            resources: [.process("Resources")]
        ),
        .executableTarget(name: "BehaviorChecks", dependencies: ["DesktopCatsCore"])
    ]
)
