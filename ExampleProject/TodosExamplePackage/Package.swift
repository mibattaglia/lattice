// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "TodosExamplePackage",
    platforms: [
        .iOS(.v26),
        .macOS(.v14),
    ],
    products: [
        .library(name: "TodosExample", targets: ["TodosExample"])
    ],
    dependencies: [
        .package(path: "../..")
    ],
    targets: [
        .target(
            name: "TodosExample",
            dependencies: [
                .product(name: "Lattice", package: "swift-lattice")
            ]
        ),
        .testTarget(
            name: "TodosExampleTests",
            dependencies: [
                "TodosExample"
            ]
        ),
    ]
)
