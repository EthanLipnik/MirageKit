//
//  MirageClientDelegate.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/2/26.
//

import MirageKit

/// Receives connection, host state, and runtime events from `MirageClientService`.
public protocol MirageClientDelegate: AnyObject, Sendable {
    /// Provides the latest host window inventory.
    @MainActor
    func didUpdateWindowList(_ windows: [MirageWindow])

    /// Reports that the active host connection ended.
    @MainActor
    func didDisconnectFromHost(reason: String)

    /// Reports a client-side runtime or protocol error.
    @MainActor
    func didEncounterError(_ error: Error)

    /// Reports the host's login, lock, sleep, or unlock availability state.
    @MainActor
    func hostSessionStateChanged(_ state: LoomSessionAvailability, requiresUserIdentifier: Bool)

}

/// Optional delegate hooks.
public extension MirageClientDelegate {
    func didUpdateWindowList(_: [MirageWindow]) {}
    func didDisconnectFromHost(reason _: String) {}
    func didEncounterError(_: Error) {}
    func hostSessionStateChanged(_: LoomSessionAvailability, requiresUserIdentifier _: Bool) {}
}
