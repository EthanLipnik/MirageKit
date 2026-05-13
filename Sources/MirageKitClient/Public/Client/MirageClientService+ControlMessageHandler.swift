//
//  MirageClientService+ControlMessageHandler.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

import MirageKit

extension MirageClientService {
    /// Dispatch target for a decoded control message type.
    enum ControlMessageHandler {
        case message(@MainActor (ControlMessage) async -> Void)
        case empty(@MainActor () async -> Void)
    }
}
