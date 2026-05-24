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

    /// Connects to an outdated host with its advertised protocol long enough to request an update install.
    func requestHostSoftwareUpdateInstallForIncompatibleHost(_ host: LoomPeer) async throws {
        let hostProtocolVersion = host.advertisement.protocolVersion
        guard hostProtocolVersion > 0 else {
            throw MirageError.protocolError("Host did not advertise a usable Mirage protocol version.")
        }

        try await connect(
            to: host,
            bootstrapProtocolVersionOverride: hostProtocolVersion
        )
        try await requestHostSoftwareUpdateInstall()
    }
}
