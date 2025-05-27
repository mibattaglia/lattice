// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "swift-feature-composer",
    platforms: [.iOS(.v15), .watchOS(.v9), .macOS(.v13)],
    products: [
        .library(
            name: "FeatureComposer",
            targets: [
                "FeatureComposer",
                "FeatureComposerTestingSupport",
            ]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/pointfreeco/combine-schedulers",
            .upToNextMajor(from: "1.0.3")
        ),
        .package(
            url: "https://github.com/pointfreeco/swift-case-paths",
            .upToNextMajor(from: "1.7.0")
        ),
    ],
    targets: [
        .target(
            name: "FeatureComposer",
            dependencies: [
                .product(name: "CombineSchedulers", package: "combine-schedulers"),
                .product(name: "CasePaths", package: "swift-case-paths"),
            ]
        ),
        .target(name: "FeatureComposerTestingSupport"),
        .testTarget(
            name: "FeatureComposerTests",
            dependencies: [
                "FeatureComposer",
                "FeatureComposerTestingSupport",
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
