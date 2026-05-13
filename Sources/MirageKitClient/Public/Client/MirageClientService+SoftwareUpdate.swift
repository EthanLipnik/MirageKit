//
//  MirageClientService+SoftwareUpdate.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/16/26.
//
//  Client host software update requests.
//

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
}
