// swift-tools-version: 6.0

import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "swift-domain-architecture",
    platforms: [.iOS(.v15), .watchOS(.v9), .macOS(.v13)],
    products: [
        .library(
            name: "DomainArchitecture",
            targets: [
                "DomainArchitecture",
                "DomainArchitectureTestingSupport",
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
        .package(
            url: "https://github.com/apple/swift-syntax",
            .upToNextMajor(from: "601.0.0")
        ),
        .package(
            url: "https://github.com/pointfreeco/swift-macro-testing",
            from: "0.2.0"
        ),
    ],
    targets: [
        .target(
            name: "DomainArchitecture",
            dependencies: [
                "DomainArchitectureMacros",
                .product(name: "CombineSchedulers", package: "combine-schedulers"),
                .product(name: "CasePaths", package: "swift-case-paths"),
            ]
        ),
        .macro(
            name: "DomainArchitectureMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]
        ),
        .target(name: "DomainArchitectureTestingSupport"),
        .testTarget(
            name: "DomainArchitectureTests",
            dependencies: [
                "DomainArchitecture",
                "DomainArchitectureTestingSupport",
            ]
        ),
        .testTarget(
            name: "DomainArchitectureMacrosTests",
            dependencies: [
                "DomainArchitectureMacros",
                .product(name: "MacroTesting", package: "swift-macro-testing"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
