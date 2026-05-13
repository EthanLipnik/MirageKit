//
//  MirageHostService+ControlMessageHandler.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

import MirageKit

extension MirageHostService {
    /// Dispatch target for a decoded host control message type.
    enum ControlMessageHandler {
        case messageAndClient(@MainActor (ControlMessage, ClientContext) async -> Void)
        case message(@MainActor (ControlMessage) async -> Void)
        case client(@MainActor (ClientContext) async -> Void)
    }
}
