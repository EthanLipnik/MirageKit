//
//  MirageClientService+MessageHandling+MenuBar.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Menu bar passthrough message handling.
//

import MirageKit

@MainActor
extension MirageClientService {
    /// Decodes a host menu-bar snapshot and publishes it to UI observers.
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
            MirageLogger.error(.menuBar, error: error, message: "Failed to decode menu bar update: ")
        }
    }

}
