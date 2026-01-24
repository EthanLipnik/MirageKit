//
//  MirageHostDelegate.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/2/26.
//

import Foundation

#if os(macOS)

/// Delegate protocol for MirageHostService events
public protocol MirageHostDelegate: AnyObject, Sendable {
    /// Called when a new connection is received, before accepting
    /// Call the completion handler with true to accept, false to reject
    @MainActor func hostService(
        _ service: MirageHostService,
        shouldAcceptConnectionFrom deviceInfo: MirageDeviceInfo,
        completion: @escaping @Sendable (Bool) -> Void
    )

    /// Called when a new client connects (after approval)
    @MainActor func hostService(_ service: MirageHostService, didConnectClient client: MirageConnectedClient)

    /// Called when a client disconnects
    @MainActor func hostService(_ service: MirageHostService, didDisconnectClient client: MirageConnectedClient)

    /// Called when a client requests to stream a window
    /// Return true to allow, false to deny
    @MainActor func hostService(_ service: MirageHostService, shouldAllowClient client: MirageConnectedClient, toStreamWindow window: MirageWindow) -> Bool

    /// Called when an input event is received from a client
    @MainActor func hostService(_ service: MirageHostService, didReceiveInputEvent event: MirageInputEvent, forWindow window: MirageWindow, fromClient client: MirageConnectedClient)

    /// Called when an error occurs
    @MainActor func hostService(_ service: MirageHostService, didEncounterError error: Error)

    /// Called when the session state changes (locked, unlocked, sleeping, etc.)
    /// Use this to update UI or take action when the Mac becomes locked/unlocked
    @MainActor func hostService(_ service: MirageHostService, sessionStateChanged state: HostSessionState)

    /// Called when a client requests to unlock the Mac
    /// Return true to allow the unlock attempt, false to deny
    /// Use this to implement additional authorization (e.g., only trusted devices can unlock)
    @MainActor func hostService(_ service: MirageHostService, shouldAllowUnlockFrom client: MirageConnectedClient) -> Bool
}

/// Default implementations
public extension MirageHostDelegate {
    func hostService(_ service: MirageHostService, shouldAcceptConnectionFrom deviceInfo: MirageDeviceInfo, completion: @escaping @Sendable (Bool) -> Void) {
        // Default: auto-accept all connections
        completion(true)
    }

    func hostService(_ service: MirageHostService, didConnectClient client: MirageConnectedClient) {}
    func hostService(_ service: MirageHostService, didDisconnectClient client: MirageConnectedClient) {}

    func hostService(_ service: MirageHostService, shouldAllowClient client: MirageConnectedClient, toStreamWindow window: MirageWindow) -> Bool {
        return true
    }

    func hostService(_ service: MirageHostService, didReceiveInputEvent event: MirageInputEvent, forWindow window: MirageWindow, fromClient client: MirageConnectedClient) {}

    func hostService(_ service: MirageHostService, didEncounterError error: Error) {}

    func hostService(_ service: MirageHostService, sessionStateChanged state: HostSessionState) {}

    func hostService(_ service: MirageHostService, shouldAllowUnlockFrom client: MirageConnectedClient) -> Bool {
        // Default: allow all connected clients to attempt unlock
        return true
    }
}

#endif
