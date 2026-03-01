//
//  MirageHostService+InputFast.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Fast input path handling.
//

import Foundation
import MirageKit

#if os(macOS)
extension MirageHostService {
    /// Fast input event handler - runs on inputQueue, NOT MainActor.
    nonisolated func handleInputEventFast(_ message: ControlMessage, from client: MirageConnectedClient) {
        do {
            let inputMessage = try InputEventMessage.deserializePayload(message.payload)

            if let loginInfo = loginDisplayInputState.getInfo(for: inputMessage.streamID) {
                handleLoginDisplayInputEvent(inputMessage.event, loginInfo: loginInfo)
                return
            }

            guard let cacheEntry = inputStreamCacheActor.get(inputMessage.streamID) else {
                MirageLogger.host("No cached stream for input: \(inputMessage.streamID)")
                return
            }

            if AppStreamRuntimeOrchestrator.isOwnershipSwitchSignal(inputMessage.event) {
                dispatchMainWork { [weak self] in
                    guard let self else { return }
                    await self.handleAppStreamOwnershipSignal(
                        streamID: inputMessage.streamID,
                        event: inputMessage.event,
                        reason: "input-fast-path"
                    )
                }
            }

            if cacheEntry.window.id == 0 {
                switch inputMessage.event {
                case .relativeResize:
                    // Desktop display sizing is driven by explicit display-resolution messages
                    // based on client view bounds, not drawable pixel caps.
                    return
                case .pixelResize:
                    // Desktop display sizing is driven by explicit display-resolution messages
                    // based on client view bounds, not drawable pixel caps.
                    return
                default:
                    break
                }
            }

            if MirageTypingBurstClassifier.shouldTrigger(for: inputMessage.event) {
                notifyTypingBurst(for: inputMessage.streamID)
            }

            if let handler = onInputEventStorage { handler(inputMessage.event, cacheEntry.window, client) } else {
                inputController.handleInputEvent(inputMessage.event, window: cacheEntry.window)
            }
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to decode input event: ")
        }
    }

    private nonisolated func notifyTypingBurst(for streamID: StreamID) {
        streamRegistry.notifyTypingBurst(streamID: streamID)
    }
}
#endif
