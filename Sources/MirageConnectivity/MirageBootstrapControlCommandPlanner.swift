//
//  MirageBootstrapControlCommandPlanner.swift
//  MirageConnectivity
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation
import Loom
import MirageCore

package enum MirageBootstrapControlEndpointSource: String, Sendable, Codable, Equatable, Hashable {
    case user
    case auto
    case lastSeen
}

package struct MirageBootstrapControlEndpoint: Sendable, Codable, Equatable, Hashable {
    package let host: String
    package let port: UInt16
    package let source: MirageBootstrapControlEndpointSource

    package init(
        host: String,
        port: UInt16,
        source: MirageBootstrapControlEndpointSource
    ) {
        self.host = host
        self.port = port
        self.source = source
    }
}

package struct MirageBootstrapControlCommandPlan: Sendable, Equatable {
    package let endpoint: MirageBootstrapControlEndpoint
    package let controlPort: UInt16
    package let controlAuthSecret: String
    package let commandIdentifier: String
    package let commandBody: Data?
    package let timeout: Duration
}

package enum MirageBootstrapControlCommandPlanner {
    package static func fallbackEndpoint(
        resolvedAddressDescriptions: [String],
        endpointHostDescription: String?,
        defaultPort: UInt16 = 22
    ) -> MirageBootstrapControlEndpoint? {
        if let resolvedHost = resolvedAddressDescriptions.first(where: { !$0.isEmpty }) {
            return MirageBootstrapControlEndpoint(
                host: resolvedHost,
                port: defaultPort,
                source: .auto
            )
        }

        guard let endpointHostDescription,
              !endpointHostDescription.isEmpty else {
            return nil
        }
        return MirageBootstrapControlEndpoint(
            host: endpointHostDescription,
            port: defaultPort,
            source: .auto
        )
    }

    package static func commandPlanIfAvailable(
        metadata: LoomBootstrapMetadata,
        fallbackEndpoint: MirageBootstrapControlEndpoint?,
        commandIdentifier: String,
        commandBody: Data?,
        timeout: Duration
    ) throws -> MirageBootstrapControlCommandPlan? {
        guard metadata.enabled,
              metadata.controlCapabilities.contains(.commands),
              let controlPort = metadata.controlPort,
              let controlAuthSecret = metadata.controlAuthSecret?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !controlAuthSecret.isEmpty else {
            return nil
        }

        let endpoints = LoomBootstrapEndpointResolver
            .resolve(metadata.endpoints)
            .map(endpoint(from:))
        guard let endpoint = endpoints.first ?? fallbackEndpoint else {
            throw MirageCore.MirageError.protocolError("Host does not advertise a usable update control endpoint.")
        }

        return MirageBootstrapControlCommandPlan(
            endpoint: endpoint,
            controlPort: controlPort,
            controlAuthSecret: controlAuthSecret,
            commandIdentifier: commandIdentifier,
            commandBody: commandBody,
            timeout: timeout
        )
    }

    @discardableResult
    package static func requestCommandIfAvailable(
        metadata: LoomBootstrapMetadata,
        fallbackEndpoint: MirageBootstrapControlEndpoint?,
        commandIdentifier: String,
        commandBody: Data?,
        identityManager: LoomIdentityManager,
        timeout: Duration
    ) async throws -> Bool {
        guard let plan = try commandPlanIfAvailable(
            metadata: metadata,
            fallbackEndpoint: fallbackEndpoint,
            commandIdentifier: commandIdentifier,
            commandBody: commandBody,
            timeout: timeout
        ) else {
            return false
        }

        let command = LoomBootstrapControlCommandPayload(
            identifier: plan.commandIdentifier,
            body: plan.commandBody
        )
        let client = LoomDefaultBootstrapControlClient(identityManager: identityManager)
        _ = try await client.requestCommand(
            endpoint: loomEndpoint(from: plan.endpoint),
            controlPort: plan.controlPort,
            controlAuthSecret: plan.controlAuthSecret,
            command: command,
            timeout: plan.timeout
        )
        return true
    }

    private static func endpoint(from endpoint: LoomBootstrapEndpoint) -> MirageBootstrapControlEndpoint {
        MirageBootstrapControlEndpoint(
            host: endpoint.host,
            port: endpoint.port,
            source: endpointSource(from: endpoint.source)
        )
    }

    private static func endpointSource(
        from source: LoomBootstrapEndpointSource
    ) -> MirageBootstrapControlEndpointSource {
        switch source {
        case .user:
            .user
        case .auto:
            .auto
        case .lastSeen:
            .lastSeen
        }
    }

    private static func loomEndpoint(from endpoint: MirageBootstrapControlEndpoint) -> LoomBootstrapEndpoint {
        LoomBootstrapEndpoint(
            host: endpoint.host,
            port: endpoint.port,
            source: loomEndpointSource(from: endpoint.source)
        )
    }

    private static func loomEndpointSource(
        from source: MirageBootstrapControlEndpointSource
    ) -> LoomBootstrapEndpointSource {
        switch source {
        case .user:
            .user
        case .auto:
            .auto
        case .lastSeen:
            .lastSeen
        }
    }
}
