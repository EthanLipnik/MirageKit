//
//  MirageHostService+AppWindowCloseAlertMessages.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

import Foundation
import MirageKit

#if os(macOS)
@MainActor
extension MirageHostService {
    /// Executes a client-selected action from a close-blocked app-window alert.
    func handleAppWindowCloseAlertActionRequest(
        _ message: ControlMessage,
        from clientContext: ClientContext
    ) async {
        do {
            let request = try message.decode(AppWindowCloseAlertActionRequestMessage.self)
            let result = await performAppWindowCloseAlertAction(
                alertToken: request.alertToken,
                actionID: request.actionID,
                presentingStreamID: request.presentingStreamID,
                clientID: clientContext.client.id
            )
            clientContext.queueBestEffort(.appWindowCloseAlertActionResult, content: result)
        } catch {
            let fallback = AppWindowCloseAlertActionResultMessage(
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
