// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "FineGrainedExamplePackage",
    platforms: [
        .iOS(.v26),
        .macOS(.v14),
    ],
    products: [
        .library(name: "FineGrainedExample", targets: ["FineGrainedExample"])
    ],
    dependencies: [
        .package(path: "../..")
    ],
    targets: [
        .target(
            name: "FineGrainedExample",
            dependencies: [
                .product(name: "Lattice", package: "lattice")
            ]
        ),
        .testTarget(
            name: "FineGrainedExampleTests",
            dependencies: [
                "FineGrainedExample"
            ]
        ),
    ]
)
