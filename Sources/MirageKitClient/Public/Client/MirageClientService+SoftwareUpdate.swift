//
//  MirageClientService+SoftwareUpdate.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/16/26.
//
//  Client host software update requests.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import Loom
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
        let request = MirageWire.HostSoftwareUpdateStatusRequestMessage(forceRefresh: forceRefresh)
        try await sendControlMessage(.hostSoftwareUpdateStatusRequest, content: request)
    }

    /// Requests host software update installation from the active host connection.
    func requestHostSoftwareUpdateInstall() async throws {
        try await sendControlMessage(MirageWire.ControlMessage(type: .hostSoftwareUpdateInstallRequest))
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

        let hostProtocolVersion = host.advertisement.mirageControlProtocolVersion
        guard hostProtocolVersion > 0 else {
            throw MirageCore.MirageError.protocolError("Host did not advertise a usable Mirage protocol version.")
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
        let helloRequest = try makeSessionHelloRequest()
        let commandBody = MirageHostSoftwareUpdateBootstrapCommand(helloRequest: helloRequest)
        let bodyData = try JSONEncoder().encode(commandBody)
        return try await MirageBootstrapControlCommandPlanner.requestCommandIfAvailable(
            metadata: bootstrapMetadata,
            fallbackEndpoint: fallbackBootstrapControlEndpoint(for: host),
            commandIdentifier: MirageBootstrapControlCommandIdentifier.hostSoftwareUpdateInstall,
            commandBody: bodyData,
            identityManager: identityManager ?? MirageKit.identityManager,
            timeout: .seconds(5)
        )
    }

    private func fallbackBootstrapControlEndpoint(for host: LoomPeer) -> MirageBootstrapControlEndpoint? {
        let endpointHostDescription: String? = switch host.endpoint {
        case let .hostPort(host, _):
            String(describing: host)
        default:
            nil
        }
        return MirageBootstrapControlCommandPlanner.fallbackEndpoint(
            resolvedAddressDescriptions: host.resolvedAddresses.map { String(describing: $0) },
            endpointHostDescription: endpointHostDescription
        )
    }
}
