// swift-tools-version: 6.2

//
//  Package.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/2/26.
//

import PackageDescription

let package = Package(
    name: "MirageKit",
    platforms: [
        .macOS("26.0"),
        .iOS("26.0"),
        .visionOS("26.0"),
    ],
    products: [
        .library(
            name: "MirageKit",
            targets: ["MirageKit"]
        ),
        .library(
            name: "MirageBootstrapShared",
            targets: ["MirageBootstrapShared"]
        ),
        .library(
            name: "MirageHostBootstrapRuntime",
            targets: ["MirageHostBootstrapRuntime"]
        ),
        .library(
            name: "MirageKitClient",
            targets: ["MirageKitClient"]
        ),
        .library(
            name: "MirageKitHost",
            targets: ["MirageKitHost"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/EthanLipnik/Loom.git", exact: "2.0.7"),
    ],
    targets: [
        .target(
            name: "MirageKit",
            dependencies: [
                .product(name: "Loom", package: "loom"),
                .product(name: "LoomCloudKit", package: "loom"),
            ]
        ),
        .target(
            name: "MirageBootstrapShared",
            dependencies: [
                "MirageKit",
                .product(name: "Loom", package: "loom"),
            ]
        ),
        .target(
            name: "MirageHostBootstrapRuntime",
            dependencies: [
                "MirageBootstrapShared",
                "MirageKit",
                .product(name: "Loom", package: "loom"),
            ]
        ),
        .target(
            name: "MirageKitClient",
            dependencies: ["MirageKit"],
            resources: [.process("Resources")]
        ),
        .target(
            name: "MirageKitHost",
            dependencies: [
                "MirageBootstrapShared",
                "MirageKit",
            ]
        ),
        .testTarget(
            name: "MirageKitTests",
            dependencies: [
                "MirageKit",
                .product(name: "Loom", package: "loom"),
            ]
        ),
        .testTarget(
            name: "MirageKitHostTests",
            dependencies: [
                "MirageKitClient",
                "MirageKitHost",
            ]
        ),
        .testTarget(
            name: "MirageHostBootstrapRuntimeTests",
            dependencies: [
                "MirageHostBootstrapRuntime",
                .product(name: "Loom", package: "loom"),
            ]
        ),
        .testTarget(
            name: "MirageKitClientTests",
            dependencies: ["MirageKitClient"]
        ),
    ]
)
