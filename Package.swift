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
        )
    ],
    targets: [
        .target(
            name: "FeatureComposer",
            dependencies: [
                .product(name: "CombineSchedulers", package: "combine-schedulers")
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
