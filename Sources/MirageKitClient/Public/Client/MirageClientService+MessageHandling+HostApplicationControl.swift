//
//  MirageClientService+MessageHandling+HostApplicationControl.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/12/26.
//
//  Client host-application control message handling.
//

import MirageKit

@MainActor
extension MirageClientService {
    /// Decodes the host restart result and forwards it to client UI observers.
    func handleHostApplicationRestartResult(_ message: ControlMessage) {
        do {
            let restartResultMessage = try message.decode(HostApplicationRestartResultMessage.self)
            onHostApplicationRestartResult?(
                HostApplicationRestartResult(
                    accepted: restartResultMessage.accepted,
                    message: restartResultMessage.message
                )
            )
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to decode host application restart result: ")
        }
    }
}
