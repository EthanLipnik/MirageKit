//
//  MirageClientService+SoftwareUpdate.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/16/26.
//
//  Client host software update requests.
//

import Loom
import MirageKit
import Network

public enum MirageIncompatibleHostSoftwareUpdateRequestPath: Sendable, Equatable {
    case bootstrapControl
    case compatibilityConnection
}

@MainActor
public extension MirageClientService {
    /// Requests host software update status from the active host connection.
    /// - Parameter forceRefresh: When true, host refreshes update metadata before replying.
    func requestHostSoftwareUpdateStatus(forceRefresh: Bool = false) async throws {
        let request = HostSoftwareUpdateStatusRequestMessage(forceRefresh: forceRefresh)
        try await sendControlMessage(.hostSoftwareUpdateStatusRequest, content: request)
    }

    /// Requests host software update installation from the active host connection.
    func requestHostSoftwareUpdateInstall() async throws {
        try await sendControlMessage(ControlMessage(type: .hostSoftwareUpdateInstallRequest))
    }

    /// Requests an update install from an outdated host using bootstrap control when available.
    @discardableResult
    func requestHostSoftwareUpdateInstallForIncompatibleHost(
        _ host: LoomPeer,
        bootstrapMetadata: LoomBootstrapMetadata? = nil
    ) async throws -> MirageIncompatibleHostSoftwareUpdateRequestPath {
        if let bootstrapMetadata,
           try await requestHostSoftwareUpdateInstallUsingBootstrapControlIfAvailable(
            host,
            bootstrapMetadata: bootstrapMetadata
           ) {
            return .bootstrapControl
        }

        let hostProtocolVersion = host.advertisement.protocolVersion
        guard hostProtocolVersion > 0 else {
            throw MirageError.protocolError("Host did not advertise a usable Mirage protocol version.")
        }

        try await connect(
            to: host,
            bootstrapProtocolVersionOverride: hostProtocolVersion
        )
        try await requestHostSoftwareUpdateInstall()
        return .compatibilityConnection
    }

    private func requestHostSoftwareUpdateInstallUsingBootstrapControlIfAvailable(
        _ host: LoomPeer,
        bootstrapMetadata: LoomBootstrapMetadata
    ) async throws -> Bool {
        guard bootstrapMetadata.enabled,
              bootstrapMetadata.controlCapabilities.contains(.commands),
              let controlPort = bootstrapMetadata.controlPort,
              let controlAuthSecret = bootstrapMetadata.controlAuthSecret?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !controlAuthSecret.isEmpty else {
            return false
        }

        let endpoints = LoomBootstrapEndpointResolver.resolve(bootstrapMetadata.endpoints)
        guard let endpoint = endpoints.first ?? fallbackBootstrapControlEndpoint(for: host) else {
            throw MirageError.protocolError("Host does not advertise a usable update control endpoint.")
        }

        let helloRequest = try makeSessionHelloRequest()
        let commandBody = MirageHostSoftwareUpdateBootstrapCommand(helloRequest: helloRequest)
        let bodyData = try JSONEncoder().encode(commandBody)
        let command = LoomBootstrapControlCommandPayload(
            identifier: MirageBootstrapControlCommandIdentifier.hostSoftwareUpdateInstall,
            body: bodyData
        )
        let client = LoomDefaultBootstrapControlClient(
            identityManager: identityManager ?? MirageKit.identityManager
        )
        _ = try await client.requestCommand(
            endpoint: endpoint,
            controlPort: controlPort,
            controlAuthSecret: controlAuthSecret,
            command: command,
            timeout: .seconds(5)
        )
        return true
    }

    private func fallbackBootstrapControlEndpoint(for host: LoomPeer) -> LoomBootstrapEndpoint? {
        if let resolvedHost = host.resolvedAddresses.first {
            return LoomBootstrapEndpoint(
                host: String(describing: resolvedHost),
                port: 22,
                source: .auto
            )
        }

        switch host.endpoint {
        case let .hostPort(host, _):
            return LoomBootstrapEndpoint(
                host: String(describing: host),
                port: 22,
                source: .auto
            )
        default:
            return nil
        }
    }
}
