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
//  MirageClientService+MessageHandling+MenuBar.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Menu bar passthrough message handling.
//


@MainActor
extension MirageClientService {
    /// Decodes a host menu-bar snapshot and publishes it to UI observers.
    func handleMenuBarUpdate(_ message: MirageWire.ControlMessage) {
        do {
            let update = try message.decode(MirageWire.MenuBarUpdateMessage.self)
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
