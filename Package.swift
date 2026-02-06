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
            name: "MirageKitClient",
            targets: ["MirageKitClient"]
        ),
        .library(
            name: "MirageKitHost",
            targets: ["MirageKitHost"]
        ),
    ],
    targets: [
        .target(
            name: "MirageKit"
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
