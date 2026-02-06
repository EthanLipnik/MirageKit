//
//  MirageClientService+MessageHandling+MenuBar.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Menu bar passthrough message handling.
//

import Foundation
import MirageKit

@MainActor
extension MirageClientService {
    func handleMenuBarUpdate(_ message: ControlMessage) {
        do {
            let update = try message.decode(MenuBarUpdateMessage.self)
            if let menuBar = update.menuBar {
                MirageLogger.log(
                    .menuBar,
                    "Received menu bar for stream \(update.streamID): \(menuBar.menus.count) menus"
                )
            } else {
                MirageLogger.log(.menuBar, "Received empty menu bar for stream \(update.streamID)")
            }
            onMenuBarUpdate?(update.streamID, update.menuBar)
        } catch {
            MirageLogger.error(.menuBar, "Failed to decode menu bar update: \(error)")
        }
    }

    func handleMenuActionResult(_ message: ControlMessage) {
        do {
            let result = try message.decode(MenuActionResultMessage.self)
            MirageLogger.log(.menuBar, "Menu action result for stream \(result.streamID): \(result.success)")
            onMenuActionResult?(result.streamID, result.success, result.errorMessage)
        } catch {
            MirageLogger.error(.menuBar, "Failed to decode menu action result: \(error)")
        }
    }
}
