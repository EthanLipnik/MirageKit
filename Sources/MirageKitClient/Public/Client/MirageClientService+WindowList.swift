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
//  MirageClientService+WindowList.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Window list request helper.
//


@MainActor
public extension MirageClientService {
    /// Request updated window list from host.
    func requestWindowList() async throws {
        try await sendControlMessage(MirageWire.ControlMessage(type: .windowListRequest))
    }
}
