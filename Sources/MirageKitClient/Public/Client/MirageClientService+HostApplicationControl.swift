//
//  MirageClientService+HostApplicationControl.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/12/26.
//
//  Client host-application control requests.
//

import MirageKit

@MainActor
public extension MirageClientService {
    /// Requests that the connected host relaunch the Mirage Host app.
    func requestHostApplicationRestart() async throws {
        try await sendControlMessage(ControlMessage(type: .hostApplicationRestartRequest))
    }
}
