//
//  MirageClientDelegate.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/2/26.
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
import Loom

/// Receives connection, stream, and host-state events from `MirageClientService`.
public protocol MirageClientDelegate: AnyObject, Sendable {
    /// Called when the client disconnects from the host.
    @MainActor
    func didDisconnectFromHost(_ reason: String)

    /// Called when the client service reports an error.
    @MainActor
    func didEncounterError(_ error: Error)

    /// Called when host session availability changes using Mirage-owned availability values.
    @MainActor
    func hostSessionAvailabilityChanged(_ availability: MirageWire.MirageHostSessionAvailability)

    /// Called when host session availability changes using the legacy Loom availability value.
    @MainActor
    func hostSessionStateChanged(_ state: LoomSessionAvailability)
}

public extension MirageClientDelegate {
    /// Called when host session availability changes using Mirage-owned availability values.
    @MainActor
    func hostSessionAvailabilityChanged(_ availability: MirageWire.MirageHostSessionAvailability) {}
}
