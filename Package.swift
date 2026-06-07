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
            name: "MirageCore",
            targets: ["MirageCore"]
        ),
        .library(
            name: "MirageIdentity",
            targets: ["MirageIdentity"]
        ),
        .library(
            name: "MirageWire",
            targets: ["MirageWire"]
        ),
        .library(
            name: "MirageMedia",
            targets: ["MirageMedia"]
        ),
        .library(
            name: "MirageDiagnostics",
            targets: ["MirageDiagnostics"]
        ),
        .library(
            name: "MirageInput",
            targets: ["MirageInput"]
        ),
        .library(
            name: "MirageConnectivity",
            targets: ["MirageConnectivity"]
        ),
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
        .package(url: "https://github.com/EthanLipnik/Loom.git", exact: "2.0.6"),
    ],
    targets: [
        .target(
            name: "MirageCore"
        ),
        .target(
            name: "MirageIdentity"
        ),
        .target(
            name: "MirageWire",
            dependencies: [
                "MirageCore",
                "MirageDiagnostics",
                "MirageInput",
                "MirageMedia",
            ]
        ),
        .target(
            name: "MirageMedia",
            dependencies: ["MirageCore"]
        ),
        .target(
            name: "MirageDiagnostics",
            dependencies: [
                "MirageCore",
                "MirageMedia",
            ]
        ),
        .target(
            name: "MirageInput",
            dependencies: ["MirageCore"]
        ),
        .target(
            name: "MirageConnectivity",
            dependencies: [
                "MirageCore",
                "MirageDiagnostics",
                "MirageIdentity",
                "MirageMedia",
                "MirageWire",
                .product(name: "Loom", package: "loom"),
            ]
        ),
        .target(
            name: "MirageKit",
            dependencies: [
                "MirageConnectivity",
                "MirageCore",
                "MirageDiagnostics",
                "MirageIdentity",
                "MirageInput",
                "MirageMedia",
                "MirageWire",
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
            dependencies: [
                "MirageConnectivity",
                "MirageDiagnostics",
                "MirageIdentity",
                "MirageKit",
                "MirageKitClientPresentation",
                "MirageWire",
            ],
            resources: [.process("Resources")]
        ),
        .target(
            name: "MirageKitClientPresentation",
            dependencies: [
                "MirageCore",
                "MirageDiagnostics",
                "MirageKit",
            ]
        ),
        .target(
            name: "MirageKitHost",
            dependencies: [
                "MirageBootstrapShared",
                "MirageConnectivity",
                "MirageDiagnostics",
                "MirageKit",
                "MirageKitClientPresentation",
                "MirageWire",
            ]
        ),
        .testTarget(
            name: "MirageKitTests",
            dependencies: [
                "MirageConnectivity",
                "MirageCore",
                "MirageDiagnostics",
                "MirageIdentity",
                "MirageInput",
                "MirageKit",
                "MirageMedia",
                "MirageWire",
                .product(name: "Loom", package: "loom"),
                .product(name: "LoomCloudKit", package: "loom"),
            ]
        ),
        .testTarget(
            name: "MirageCoreTests",
            dependencies: ["MirageCore"]
        ),
        .testTarget(
            name: "MirageIdentityTests",
            dependencies: ["MirageIdentity"]
        ),
        .testTarget(
            name: "MirageWireTests",
            dependencies: [
                "MirageCore",
                "MirageDiagnostics",
                "MirageInput",
                "MirageMedia",
                "MirageWire",
            ]
        ),
        .testTarget(
            name: "MirageMediaTests",
            dependencies: [
                "MirageCore",
                "MirageMedia",
            ]
        ),
        .testTarget(
            name: "MirageDiagnosticsTests",
            dependencies: [
                "MirageCore",
                "MirageDiagnostics",
                "MirageMedia",
            ]
        ),
        .testTarget(
            name: "MirageInputTests",
            dependencies: ["MirageInput"]
        ),
        .testTarget(
            name: "MirageConnectivityTests",
            dependencies: [
                "MirageConnectivity",
                "MirageCore",
                "MirageDiagnostics",
                "MirageIdentity",
                "MirageMedia",
                "MirageWire",
                .product(name: "Loom", package: "loom"),
            ]
        ),
        .testTarget(
            name: "MiragePublicImportBoundaryTests",
            dependencies: [
                "MirageCore",
                "MirageDiagnostics",
                "MirageIdentity",
                "MirageInput",
                "MirageMedia",
                "MirageWire",
            ]
        ),
        .testTarget(
            name: "MirageKitHostTests",
            dependencies: [
                "MirageBootstrapShared",
                "MirageConnectivity",
                "MirageCore",
                "MirageDiagnostics",
                "MirageIdentity",
                "MirageInput",
                "MirageKitHost",
                "MirageMedia",
                "MirageWire",
                .product(name: "Loom", package: "loom"),
            ]
        ),
        .testTarget(
            name: "MirageHostBootstrapRuntimeTests",
            dependencies: [
                "MirageBootstrapShared",
                "MirageHostBootstrapRuntime",
                .product(name: "Loom", package: "loom"),
            ]
        ),
        .testTarget(
            name: "MirageKitClientTests",
            dependencies: [
                "MirageConnectivity",
                "MirageCore",
                "MirageDiagnostics",
                "MirageIdentity",
                "MirageInput",
                "MirageKitClient",
                "MirageKitClientPresentation",
                "MirageMedia",
                "MirageWire",
                .product(name: "Loom", package: "loom"),
            ]
        ),
        .testTarget(
            name: "MirageKitClientPresentationTests",
            dependencies: [
                "MirageDiagnostics",
                "MirageKit",
                "MirageKitClientPresentation",
            ]
        ),
    ]
)
