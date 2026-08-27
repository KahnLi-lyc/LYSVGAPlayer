// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LYSVGAPlayer",
    platforms: [
        .iOS(.v16),
    ],
    products: [
        .library(
            name: "LYSVGAPlayer",
            targets: ["LYSVGAPlayer"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-protobuf.git",
            from: "1.27.0"
        ),
        .package(
            url: "https://github.com/weichsel/ZIPFoundation.git",
            from: "0.9.19"
        ),
    ],
    targets: [
        .target(
            name: "LYSVGAPlayer",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
        .testTarget(
            name: "LYSVGAPlayerTests",
            dependencies: ["LYSVGAPlayer"]
        ),
    ]
)
