//
//  MirageHostService+WindowActivation.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Window activation helpers.
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

extension MirageHostService {
    func activateWindow(_ window: MirageMedia.MirageWindow) async {
        guard window.application != nil else {
            MirageLogger.host("Cannot activate window - no associated application")
            return
        }

        do {
            try await platformWindowCatalogBackend.activateWindow(window)
        } catch {
            MirageLogger.error(.host, error: error, message: "Window activation failed: ")
        }
    }
}
#endif
