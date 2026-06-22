//
//  MirageRenderStreamStore+Listeners.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/10/26.
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
import Foundation

extension MirageRenderStreamStore {
    /// Registers a weakly-owned callback that fires when a stream receives a new decoded frame.
    func registerFrameListener(
        for streamID: StreamID,
        owner: AnyObject,
        callback: @escaping @Sendable () -> Void
    ) {
        let state = streamState(for: streamID)
        state.lock.lock()
        let key = ObjectIdentifier(owner)
        state.listeners[key] = MirageRenderStreamFrameListener(
            owner: MirageRenderStreamWeakOwner(owner),
            callback: callback
        )
        state.lock.unlock()
    }

    /// Removes a frame listener for a stream and owner pair.
    func unregisterFrameListener(for streamID: StreamID, owner: AnyObject) {
        guard let state = streamStateIfPresent(for: streamID) else { return }
        state.lock.lock()
        state.listeners.removeValue(forKey: ObjectIdentifier(owner))
        state.lock.unlock()
    }

    /// Registers a weakly-owned callback used to ask renderers to rebuild stalled presentation state.
    func registerPresentationRecoveryHandler(
        for streamID: StreamID,
        owner: AnyObject,
        callback: @escaping @Sendable () -> Void
    ) {
        let state = streamState(for: streamID)
        state.lock.lock()
        let key = ObjectIdentifier(owner)
        state.presentationRecoveryHandlers[key] = MirageRenderStreamFrameListener(
            owner: MirageRenderStreamWeakOwner(owner),
            callback: callback
        )
        state.lock.unlock()
    }

    /// Removes a presentation recovery callback for a stream and owner pair.
    func unregisterPresentationRecoveryHandler(for streamID: StreamID, owner: AnyObject) {
        guard let state = streamStateIfPresent(for: streamID) else { return }
        state.lock.lock()
        state.presentationRecoveryHandlers.removeValue(forKey: ObjectIdentifier(owner))
        state.lock.unlock()
    }

    /// Invokes active presentation recovery handlers and prunes stale weak owners.
    func requestPresentationRecovery(for streamID: StreamID) -> Bool {
        guard let state = streamStateIfPresent(for: streamID) else { return false }

        state.lock.lock()
        let callbacks = activePresentationRecoveryHandlersLocked(state: state)
        state.lock.unlock()

        for callback in callbacks {
            callback()
        }

        return !callbacks.isEmpty
    }
}
