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
//  MirageHostService+ControlMessageHandler.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//


extension MirageHostService {
    /// Dispatch target for a decoded host control message type.
    enum ControlMessageHandler {
        case messageAndClient(@MainActor (MirageWire.ControlMessage, ClientContext) async -> Void)
        case message(@MainActor (MirageWire.ControlMessage) async -> Void)
        case client(@MainActor (ClientContext) async -> Void)
    }
}
