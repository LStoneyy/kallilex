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
        .library(name: "KallilexUI", targets: ["KallilexUI"]),
        .library(name: "KallilexKeyboardCore", targets: ["KallilexKeyboardCore"]),
    ],
    targets: [
        .target(
            name: "KallilexKit",
            dependencies: [],
            resources: [.process("Resources")]
        ),
        .target(
            name: "KallilexUI",
            dependencies: ["KallilexKit"],
            resources: [.process("Resources")]
        ),
        .target(
            name: "KallilexKeyboardCore",
            dependencies: []
        ),
        .testTarget(
            name: "KallilexKitTests",
            dependencies: ["KallilexKit", "KallilexUI"]
        ),
        .testTarget(
            name: "KallilexKeyboardCoreTests",
            dependencies: ["KallilexKeyboardCore"]
        ),
    ]
)
