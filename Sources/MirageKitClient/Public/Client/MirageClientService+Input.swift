import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
//
//  MirageClientService+Input.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Client input event dispatch.
//


public extension MirageClientService {
    /// Send an input event to the host with network confirmation.
    nonisolated func sendInput(_ event: MirageInput.MirageInputEvent, forStream streamID: StreamID) async throws {
        MirageRenderStreamStore.shared.noteInteraction(for: streamID)
        try await inputEventSender.sendInput(event, streamID: streamID)
    }

    /// Send an input event to the host without waiting for network confirmation.
    nonisolated func sendInputFireAndForget(_ event: MirageInput.MirageInputEvent, forStream streamID: StreamID) {
        MirageRenderStreamStore.shared.noteInteraction(for: streamID)
        inputEventSender.sendInputFireAndForget(event, streamID: streamID)
    }
}
