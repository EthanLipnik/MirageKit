//
//  MirageClientDelegate.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/2/26.
//

import CoreGraphics
import Foundation
import MirageKit

/// Delegate protocol for MirageClientService events
public protocol MirageClientDelegate: AnyObject, Sendable {
    /// Called when the window list is updated
    @MainActor
    func clientService(_ service: MirageClientService, didUpdateWindowList windows: [MirageWindow])

    /// Called when a video packet is received
    @MainActor
    func clientService(
        _ service: MirageClientService,
        didReceiveVideoPacket data: Data,
        forStream streamID: StreamID
    )

    /// Called when disconnected from host
    @MainActor
    func clientService(_ service: MirageClientService, didDisconnectFromHost reason: String)

    /// Called when an error occurs
    @MainActor
    func clientService(_ service: MirageClientService, didEncounterError error: Error)

    /// Called when content bounds change (menus, sheets appear on virtual display)
    @MainActor
    func clientService(
        _ service: MirageClientService,
        didReceiveContentBoundsUpdate bounds: CGRect,
        forStream streamID: StreamID
    )

    /// Called when the host's session state changes (locked, unlocked, sleeping, etc.)
    /// Use this to show unlock UI when the host is locked
    @MainActor
    func clientService(
        _ service: MirageClientService,
        hostSessionStateChanged state: LoomSessionAvailability,
        requiresUserIdentifier: Bool
    )

}

/// Default implementations
public extension MirageClientDelegate {
    func clientService(_: MirageClientService, didUpdateWindowList _: [MirageWindow]) {}
    func clientService(_: MirageClientService, didReceiveVideoPacket _: Data, forStream _: StreamID) {}
    func clientService(_: MirageClientService, didDisconnectFromHost _: String) {}
    func clientService(_: MirageClientService, didEncounterError _: Error) {}
    func clientService(_: MirageClientService, didReceiveContentBoundsUpdate _: CGRect, forStream _: StreamID) {}
    func clientService(_: MirageClientService, hostSessionStateChanged _: LoomSessionAvailability, requiresUserIdentifier _: Bool) {}
}
