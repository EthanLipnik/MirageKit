//
//  MirageClientLabs.swift
//  MirageKitClient
//
//  Created by Ethan Lipnik on 6/5/26.
//

import MirageConnectivity
import MirageCore
@_spi(Labs) import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import Foundation

/// Registry for client Labs backed by MirageKitClient measurements.
@_spi(Labs)
public struct MirageClientLabRegistry: Sendable {
    private let registry: MirageDiagnostics.MirageLabRegistry

    public init() {
        registry = MirageDiagnostics.MirageLabRegistry()
    }

    public init(runners: [any MirageDiagnostics.MirageLabRunner]) throws {
        registry = try MirageDiagnostics.MirageLabRegistry(runners: runners)
    }

    public static func standard() -> MirageClientLabRegistry {
        MirageClientLabRegistry()
    }

    public var descriptors: [MirageDiagnostics.MirageLabDescriptor] {
        registry.descriptors
    }

    public func descriptor(id: String) -> MirageDiagnostics.MirageLabDescriptor? {
        registry.descriptor(id: id)
    }

    public func runner(id: String) -> (any MirageDiagnostics.MirageLabRunner)? {
        registry.runner(id: id)
    }

    public func run(
        id: String,
        configuration: MirageDiagnostics.MirageLabConfiguration? = nil,
        progress: MirageDiagnostics.MirageLabProgressHandler? = nil
    ) async throws -> MirageDiagnostics.MirageLabReport {
        try await registry.run(
            id: id,
            configuration: configuration,
            progress: progress
        )
    }
}
