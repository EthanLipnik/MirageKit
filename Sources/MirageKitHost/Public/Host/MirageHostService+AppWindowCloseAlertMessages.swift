//
//  MirageHostService+AppWindowCloseAlertMessages.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import Foundation

#if os(macOS)
@MainActor
extension MirageHostService {
    /// Executes a client-selected action from a close-blocked app-window alert.
    func handleAppWindowCloseAlertActionRequest(
        _ message: MirageWire.ControlMessage,
        from clientContext: ClientContext
    ) async {
        do {
            let request = try message.decode(MirageWire.AppWindowCloseAlertActionRequestMessage.self)
            let result = await performAppWindowCloseAlertAction(
                alertToken: request.alertToken,
                actionID: request.actionID,
                presentingStreamID: request.presentingStreamID,
                clientID: clientContext.client.id
            )
            clientContext.queueBestEffort(.appWindowCloseAlertActionResult, content: result)
        } catch {
            let fallback = MirageWire.AppWindowCloseAlertActionResultMessage(
                alertToken: "",
                actionID: "",
                success: false,
                reason: error.localizedDescription
            )
            clientContext.queueBestEffort(.appWindowCloseAlertActionResult, content: fallback)
        }
    }
}
#endif
