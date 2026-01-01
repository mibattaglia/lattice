// swift-tools-version: 6.0

import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "swift-uno-architecture",
    platforms: [.iOS(.v17), .watchOS(.v10), .macOS(.v14)],
    products: [
        .library(
            name: "UnoArchitecture",
            targets: ["UnoArchitecture"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-async-algorithms",
            .upToNextMajor(from: "1.0.0")
        ),
        .package(
            url: "https://github.com/pointfreeco/combine-schedulers",
            .upToNextMajor(from: "1.0.3")
        ),
        .package(
            url: "https://github.com/pointfreeco/swift-case-paths",
            .upToNextMajor(from: "1.7.0")
        ),
        .package(
            url: "https://github.com/apple/swift-syntax",
            .upToNextMajor(from: "601.0.0")
        ),
        .package(
            url: "https://github.com/pointfreeco/swift-macro-testing",
            from: "0.2.0"
        ),
        .package(
            url: "https://github.com/pointfreeco/swift-clocks",
            .upToNextMajor(from: "1.0.0")
        ),
        .package(url: "https://github.com/apple/swift-collections", from: "1.1.0"),
        .package(url: "https://github.com/pointfreeco/swift-identified-collections", from: "1.1.0"),
    ],
    targets: [
        .target(
            name: "UnoArchitecture",
            dependencies: [
                "UnoArchitectureMacros",
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
                .product(name: "CombineSchedulers", package: "combine-schedulers"),
                .product(name: "CasePaths", package: "swift-case-paths"),
                .product(name: "Clocks", package: "swift-clocks"),
                .product(name: "IdentifiedCollections", package: "swift-identified-collections"),
                .product(name: "OrderedCollections", package: "swift-collections"),
            ]
        ),
        .macro(
            name: "UnoArchitectureMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]
        ),
        .testTarget(
            name: "UnoArchitectureTests",
            dependencies: [
                "UnoArchitecture"
            ]
        ),
        .testTarget(
            name: "UnoArchitectureMacrosTests",
            dependencies: [
                "UnoArchitectureMacros",
                .product(name: "MacroTesting", package: "swift-macro-testing"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
