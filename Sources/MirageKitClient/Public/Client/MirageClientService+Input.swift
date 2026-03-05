//
//  MirageClientService+Input.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Client input event dispatch.
//

import Foundation
import MirageKit

public extension MirageClientService {
    /// Send an input event to the host with network confirmation.
    nonisolated func sendInput(_ event: MirageInputEvent, forStream streamID: StreamID) async throws {
        try await inputEventSender.sendInput(event, streamID: streamID)
    }

    /// Send an input event to the host without waiting for network confirmation.
    nonisolated func sendInputFireAndForget(_ event: MirageInputEvent, forStream streamID: StreamID) {
        inputEventSender.sendInputFireAndForget(event, streamID: streamID)
    }
}
