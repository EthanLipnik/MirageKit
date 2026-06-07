//
//  MirageHostDelegate.swift
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
        _ event: MirageInput.MirageInputEvent,
        forWindow window: MirageMedia.MirageWindow
    )

    /// Called when host session availability changes, such as lock, unlock, or sleep.
    @MainActor
    func sessionStateDidChange(_ state: LoomSessionAvailability)

    /// Called when host session availability changes using Mirage-owned availability values.
    @MainActor
    func sessionAvailabilityDidChange(_ availability: MirageWire.MirageHostSessionAvailability)

    /// Called early in the incoming session when the Loom handshake completes and the peer
    /// advertisement is available, before Mirage session bootstrap finishes.
    @MainActor
    func didDiscoverPeer(advertisement: LoomPeerAdvertisement)

}

public extension MirageHostDelegate {
    /// Called when host session availability changes using Mirage-owned availability values.
    @MainActor
    func sessionAvailabilityDidChange(_ availability: MirageWire.MirageHostSessionAvailability) {}
}

#endif
