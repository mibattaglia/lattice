// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ScopedCompositionExamplePackage",
    platforms: [
        .iOS(.v26),
        .macOS(.v14),
    ],
    products: [
        .library(name: "ScopedCompositionExample", targets: ["ScopedCompositionExample"])
    ],
    dependencies: [
        .package(path: "../..")
    ],
    targets: [
        .target(
            name: "ScopedCompositionExample",
            dependencies: [
                .product(name: "Lattice", package: "lattice")
            ]
        ),
        .testTarget(
            name: "ScopedCompositionExampleTests",
            dependencies: [
                "ScopedCompositionExample"
            ]
        ),
    ]
)
