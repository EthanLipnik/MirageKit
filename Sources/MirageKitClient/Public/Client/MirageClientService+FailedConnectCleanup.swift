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
//  MirageClientService+FailedConnectCleanup.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

@MainActor
extension MirageClientService {
    /// Returns whether a failed connection attempt left session state that needs normal disconnect cleanup.
    var requiresDisconnectCleanupAfterFailedConnect: Bool {
        switch connectionState {
        case .disconnected, .error:
            controlChannel != nil || loomSession != nil
        case .connecting, .handshaking, .connected, .reconnecting:
            true
        }
    }
}
