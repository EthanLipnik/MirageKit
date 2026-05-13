//
//  MirageClientDelegate.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/2/26.
//

import MirageKit

/// Receives connection, stream, and host-state events from `MirageClientService`.
public protocol MirageClientDelegate: AnyObject, Sendable {
    /// Called when the client disconnects from the host.
    @MainActor
    func didDisconnectFromHost(_ reason: String)

    /// Called when the client service reports an error.
    @MainActor
    func didEncounterError(_ error: Error)

    /// Called when host session availability changes.
    @MainActor
    func hostSessionStateChanged(_ state: LoomSessionAvailability)
}
