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
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.12.0"),
    ],
    targets: [
        .target(
            name: "MirageKit",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
            ]
        ),
        .target(
            name: "MirageBootstrapShared"
        ),
        .target(
            name: "MirageHostBootstrapRuntime",
            dependencies: ["MirageBootstrapShared"]
        ),
        .target(
            name: "MirageKitClient",
            dependencies: ["MirageKit"]
        ),
        .target(
            name: "MirageKitHost",
            dependencies: ["MirageKit"]
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
            name: "MirageKitClientTests",
            dependencies: ["MirageKitClient"]
        ),
    ]
)
