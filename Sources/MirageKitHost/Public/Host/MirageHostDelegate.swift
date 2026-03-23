//
//  MirageHostDelegate.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/2/26.
//

import Foundation
import MirageKit

#if os(macOS)

/// Delegate protocol for MirageHostService events
public protocol MirageHostDelegate: AnyObject, Sendable {
    /// Called when a new connection is received, before accepting
    /// Call the completion handler with true to accept, false to reject
    @MainActor
    func hostService(
        _ service: MirageHostService,
        shouldAcceptConnectionFrom deviceInfo: LoomPeerDeviceInfo,
        origin: MirageHostConnectionOrigin,
        completion: @escaping @Sendable (Bool) -> Void
    )

    /// Called when a new client connects (after approval)
    @MainActor
    func hostService(_ service: MirageHostService, didConnectClient client: MirageConnectedClient)

    /// Called when a client disconnects
    @MainActor
    func hostService(_ service: MirageHostService, didDisconnectClient client: MirageConnectedClient)

    /// Called when an input event is received from a client
    @MainActor
    func hostService(
        _ service: MirageHostService,
        didReceiveInputEvent event: MirageInputEvent,
        forWindow window: MirageWindow,
        fromClient client: MirageConnectedClient
    )

    /// Called when the session state changes (locked, unlocked, sleeping, etc.)
    /// Use this to update UI or take action when the Mac becomes locked/unlocked
    @MainActor
    func hostService(_ service: MirageHostService, sessionStateChanged state: LoomSessionAvailability)

    /// Called early in the incoming session when the Loom handshake completes and the peer
    /// advertisement is available, before full Mirage bootstrap negotiation.
    @MainActor
    func hostService(_ service: MirageHostService, didDiscoverPeerWithAdvertisement advertisement: LoomPeerAdvertisement)

    /// Called after an authenticated hello is accepted so the host can advertise whether
    /// this client should remember remote signaling access for future sessions.
    @MainActor
    func hostService(_ service: MirageHostService, remoteAccessAllowedFor deviceInfo: LoomPeerDeviceInfo)
        -> Bool
}

/// Default implementations
public extension MirageHostDelegate {
    func hostService(
        _: MirageHostService,
        shouldAcceptConnectionFrom _: LoomPeerDeviceInfo,
        origin _: MirageHostConnectionOrigin,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        // Default: auto-accept all connections
        completion(true)
    }

    func hostService(_: MirageHostService, didConnectClient _: MirageConnectedClient) {}
    func hostService(_: MirageHostService, didDisconnectClient _: MirageConnectedClient) {}

    func hostService(
        _: MirageHostService,
        didReceiveInputEvent _: MirageInputEvent,
        forWindow _: MirageWindow,
        fromClient _: MirageConnectedClient
    ) {}

    func hostService(_: MirageHostService, sessionStateChanged _: LoomSessionAvailability) {}

    func hostService(_: MirageHostService, didDiscoverPeerWithAdvertisement _: LoomPeerAdvertisement) {}

    func hostService(_: MirageHostService, remoteAccessAllowedFor _: LoomPeerDeviceInfo) -> Bool {
        false
    }
}

#endif
