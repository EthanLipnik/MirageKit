import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
//
//  MirageClientService+HostApplicationControl.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/12/26.
//
//  Client host-application control requests.
//


@MainActor
public extension MirageClientService {
    /// Requests that the connected host relaunch the Mirage Host app.
    func requestHostApplicationRestart() async throws {
        try await sendControlMessage(MirageWire.ControlMessage(type: .hostApplicationRestartRequest))
    }
}
