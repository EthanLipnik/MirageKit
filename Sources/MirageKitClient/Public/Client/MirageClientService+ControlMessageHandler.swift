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
//  MirageClientService+ControlMessageHandler.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//


extension MirageClientService {
    /// Dispatch target for a decoded control message type.
    enum ControlMessageHandler {
        case message(@MainActor (MirageWire.ControlMessage) async -> Void)
        case empty(@MainActor () async -> Void)
    }
}
