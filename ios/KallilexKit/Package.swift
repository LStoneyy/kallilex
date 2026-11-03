// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "KallilexKit",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v26)
    ],
    products: [
        .library(name: "KallilexKit", targets: ["KallilexKit"]),
    ],
    targets: [
        .target(
            name: "KallilexKit",
            dependencies: [],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "KallilexKitTests",
            dependencies: ["KallilexKit"]
        ),
    ]
)
