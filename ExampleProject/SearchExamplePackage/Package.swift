// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "SearchExamplePackage",
    platforms: [
        .iOS(.v26)
    ],
    products: [
        .library(name: "SearchExample", targets: ["SearchExample"])
    ],
    dependencies: [
        .package(path: "../..")
    ],
    targets: [
        .target(
            name: "SearchExample",
            dependencies: [
                .product(name: "Lattice", package: "swift-lattice")
            ]
        ),
        .testTarget(
            name: "SearchExampleTests",
            dependencies: [
                "SearchExample"
            ]
        ),
    ]
)
