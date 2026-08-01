// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "SearchExamplePackage",
    platforms: [
        .iOS(.v26),
        .macOS(.v14),
    ],
    products: [
        .library(name: "SearchExample", targets: ["SearchExample"])
    ],
    dependencies: [
        .package(path: "../.."),
        .package(url: "https://github.com/pointfreeco/swift-identified-collections", from: "1.1.0"),
        .package(url: "https://github.com/pointfreeco/swift-case-paths", .upToNextMajor(from: "1.7.0")),
        .package(url: "https://github.com/pointfreeco/swift-clocks", .upToNextMajor(from: "1.0.0")),
    ],
    targets: [
        .target(
            name: "SearchExample",
            dependencies: [
                .product(name: "Lattice", package: "lattice"),
                .product(name: "IdentifiedCollections", package: "swift-identified-collections"),
                .product(name: "CasePaths", package: "swift-case-paths"),
            ]
        ),
        .testTarget(
            name: "SearchExampleTests",
            dependencies: [
                "SearchExample",
                .product(name: "Clocks", package: "swift-clocks"),
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
