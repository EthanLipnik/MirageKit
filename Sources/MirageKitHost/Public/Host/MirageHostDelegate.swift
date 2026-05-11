//
//  MirageHostDelegate.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/2/26.
//

import MirageKit

#if os(macOS)

/// Receives host lifecycle, connection, stream, and input events from `MirageHostService`.
public protocol MirageHostDelegate: AnyObject, Sendable {
    /// Asks whether an incoming authenticated peer should be allowed to finish connecting.
    @MainActor
    func shouldAcceptConnection(
        from deviceInfo: LoomPeerDeviceInfo,
        origin: MirageHostConnectionOrigin,
        completion: @escaping @Sendable (Bool) -> Void
    )

    /// Called after a client has been approved and connected.
    @MainActor
    func didConnectClient(_ client: MirageConnectedClient)

    /// Called after a connected client disconnects.
    @MainActor
    func didDisconnectClient(_ client: MirageConnectedClient)

    /// Called when active desktop or app stream state changes.
    @MainActor
    func activeStreamsDidChange()

    /// Called when a connected client sends an input event for a host window.
    @MainActor
    func didReceiveInputEvent(
        _ event: MirageInputEvent,
        forWindow window: MirageWindow
    )

    /// Called when host session availability changes, such as lock, unlock, or sleep.
    @MainActor
    func sessionStateDidChange(_ state: LoomSessionAvailability)

    /// Called early in the incoming session when the Loom handshake completes and the peer
    /// advertisement is available, before full Mirage bootstrap negotiation.
    @MainActor
    func didDiscoverPeer(advertisement: LoomPeerAdvertisement)

    /// Called after an authenticated hello is accepted so the host can advertise whether clients
    /// may reuse host-published off-LAN access metadata for future sessions.
    @MainActor
    var remoteAccessAllowedForConnections: Bool { get }
}

#endif
