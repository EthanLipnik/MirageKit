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
        hostSessionStateChanged state: HostSessionState,
        requiresUsername: Bool
    )

    /// Called when an unlock attempt completes
    /// - Parameters:
    ///   - success: Whether the unlock was successful
    ///   - error: Error message if unlock failed
    ///   - canRetry: Whether the client can retry with the same credentials
    ///   - retriesRemaining: Number of retries remaining before rate limiting
    ///   - retryAfterSeconds: Seconds to wait before retrying (if rate limited)
    @MainActor
    func clientService(
        _ service: MirageClientService,
        unlockDidComplete success: Bool,
        error: String?,
        canRetry: Bool,
        retriesRemaining: Int?,
        retryAfterSeconds: Int?
    )

    /// Called when the host starts streaming the login display (for remote unlock)
    /// The client should show this stream and allow the user to type their password
    /// - Parameters:
    ///   - streamID: Stream ID for the login display
    ///   - resolution: Resolution of the login display
    ///   - sessionState: Current session state (screenLocked, loginScreen, etc.)
    ///   - requiresUsername: Whether username is needed (true for loginScreen, false for screenLocked)
    @MainActor
    func clientService(
        _ service: MirageClientService,
        loginDisplayDidStart streamID: StreamID,
        resolution: CGSize,
        sessionState: HostSessionState,
        requiresUsername: Bool
    )

    /// Called when the login display stream stops (user logged in successfully)
    /// The client should transition to normal window selection mode
    /// - Parameters:
    ///   - streamID: Stream ID that was stopped
    ///   - newState: New session state (should be .active)
    @MainActor
    func clientService(
        _ service: MirageClientService,
        loginDisplayDidStop streamID: StreamID,
        newState: HostSessionState
    )
}

/// Default implementations
public extension MirageClientDelegate {
    func clientService(_: MirageClientService, didUpdateWindowList _: [MirageWindow]) {}
    func clientService(_: MirageClientService, didReceiveVideoPacket _: Data, forStream _: StreamID) {}
    func clientService(_: MirageClientService, didDisconnectFromHost _: String) {}
    func clientService(_: MirageClientService, didEncounterError _: Error) {}
    func clientService(_: MirageClientService, didReceiveContentBoundsUpdate _: CGRect, forStream _: StreamID) {}
    func clientService(_: MirageClientService, hostSessionStateChanged _: HostSessionState, requiresUsername _: Bool) {}
    func clientService(
        _: MirageClientService,
        unlockDidComplete _: Bool,
        error _: String?,
        canRetry _: Bool,
        retriesRemaining _: Int?,
        retryAfterSeconds _: Int?
    ) {}
    func clientService(
        _: MirageClientService,
        loginDisplayDidStart _: StreamID,
        resolution _: CGSize,
        sessionState _: HostSessionState,
        requiresUsername _: Bool
    ) {}
    func clientService(_: MirageClientService, loginDisplayDidStop _: StreamID, newState _: HostSessionState) {}
}
