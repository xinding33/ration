// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Ration",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Ration", targets: ["Ration"])],
    targets: [
        .target(name: "RationCore"),
        .executableTarget(name: "Ration", dependencies: ["RationCore"]),
        .testTarget(name: "RationCoreTests", dependencies: ["RationCore"])
    ]
)
