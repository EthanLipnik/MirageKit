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
        .macOS(.v14),
        .iOS("17.4"),
        .visionOS(.v26),
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
        .package(url: "https://github.com/EthanLipnik/Loom.git", exact: "1.6.17"),
    ],
    targets: [
        .target(
            name: "MirageKit",
            dependencies: [
                .product(name: "Loom", package: "Loom"),
                .product(name: "LoomCloudKit", package: "Loom"),
            ]
        ),
        .target(
            name: "MirageBootstrapShared",
            dependencies: [
                "MirageKit",
                .product(name: "Loom", package: "Loom"),
            ]
        ),
        .target(
            name: "MirageHostBootstrapRuntime",
            dependencies: [
                "MirageBootstrapShared",
                .product(name: "Loom", package: "Loom"),
            ]
        ),
        .target(
            name: "MirageKitClient",
            dependencies: ["MirageKit"]
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
            dependencies: ["MirageKit"]
        ),
        .testTarget(
            name: "MirageKitHostTests",
            dependencies: ["MirageKitHost"]
        ),
        .testTarget(
            name: "MirageHostBootstrapRuntimeTests",
            dependencies: [
                "MirageHostBootstrapRuntime",
                .product(name: "Loom", package: "Loom"),
            ]
        ),
        .testTarget(
            name: "MirageKitClientTests",
            dependencies: ["MirageKitClient"]
        ),
    ]
)
