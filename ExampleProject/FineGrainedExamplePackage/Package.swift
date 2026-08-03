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
        .package(path: "../.."),
        .package(url: "https://github.com/pointfreeco/swift-case-paths", .upToNextMajor(from: "1.7.0")),
    ],
    targets: [
        .target(
            name: "FineGrainedExample",
            dependencies: [
                .product(name: "Lattice", package: "lattice"),
                .product(name: "CasePaths", package: "swift-case-paths"),
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

for target in package.targets {
    target.swiftSettings = target.swiftSettings ?? []
    target.swiftSettings?.append(contentsOf: [
        .enableUpcomingFeature("InferIsolatedConformances"),
        .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    ])
}
