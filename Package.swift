// swift-tools-version: 6.2

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
            from: "1.38.1"
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
            ],
            exclude: [
                "Format/Protobuf/README.md",
                "Format/Protobuf/svga.proto",
            ]
        ),
        .testTarget(
            name: "LYSVGAPlayerTests",
            dependencies: ["LYSVGAPlayer"],
            resources: [
                .copy("Fixtures"),
                .copy("ImageViewFixture.svga"),
            ]
        ),
        .testTarget(
            name: "LYSVGABenchmarks",
            dependencies: ["LYSVGAPlayer"],
            path: "Benchmarks/LYSVGABenchmarks",
            resources: [
                .copy("Fixtures"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
