// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "OasesCPA",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "OasesCPA", targets: ["OasesCPA"])
    ],
    targets: [
        .executableTarget(
            name: "OasesCPA",
            path: "Sources/OasesCPA",
            exclude: [
                "Resources/Info.plist"
            ],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "OasesCPATests",
            dependencies: ["OasesCPA"],
            path: "Tests/OasesCPATests"
        )
    ]
)
