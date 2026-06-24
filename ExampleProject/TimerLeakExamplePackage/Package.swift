// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "TimerLeakExamplePackage",
    platforms: [
        .iOS(.v26)
    ],
    products: [
        .library(name: "TimerLeakExample", targets: ["TimerLeakExample"])
    ],
    dependencies: [
        .package(path: "../..")
    ],
    targets: [
        .target(
            name: "TimerLeakExample",
            dependencies: [
                .product(name: "Lattice", package: "lattice")
            ]
        ),
        .testTarget(
            name: "TimerLeakExampleTests",
            dependencies: [
                "TimerLeakExample"
            ]
        ),
    ]
)
