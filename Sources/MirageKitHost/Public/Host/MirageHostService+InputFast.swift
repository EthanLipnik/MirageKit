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
    nonisolated func handleInputEventFast(
        _ message: ControlMessage,
        from client: MirageConnectedClient,
        sessionID: UUID
    ) {
        let sessionActive = streamRegistry.isInputSessionActive(sessionID, clientID: client.id)
        guard sessionActive else { return }

        do {
            let inputMessage = try InputEventMessage.deserializePayload(message.payload)
            HostKeyboardInputDiagnostics.logReceive(
                event: inputMessage.event,
                streamID: inputMessage.streamID,
                sessionActive: sessionActive,
                path: "input_fast"
            )

            if let customInputHandler = streamRegistry.customInputHandler(streamID: inputMessage.streamID) {
                HostKeyboardInputDiagnostics.logTargetResolution(
                    event: inputMessage.event,
                    streamID: inputMessage.streamID,
                    targetState: "custom_handler",
                    path: "input_fast"
                )
                Task(priority: .userInitiated) {
                    await customInputHandler.handleInput(inputMessage.event, streamID: inputMessage.streamID)
                }
                return
            }

            guard let inputTarget = inputStreamCache.resolveInputTarget(
                streamID: inputMessage.streamID,
                event: inputMessage.event
            ) else {
                HostKeyboardInputDiagnostics.logTargetResolution(
                    event: inputMessage.event,
                    streamID: inputMessage.streamID,
                    targetState: "missing_cache",
                    path: "input_fast"
                )
                MirageLogger.host("No cached stream for input: \(inputMessage.streamID)")
                return
            }
            HostKeyboardInputDiagnostics.logTargetResolution(
                event: inputTarget.event,
                streamID: inputMessage.streamID,
                targetState: inputTarget.window.id == 0 ? "desktop_active" : "window_\(inputTarget.window.id)",
                path: "input_fast"
            )

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

            if inputTarget.window.id == 0 {
                switch inputTarget.event {
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

            if let handler = onInputEvent { handler(inputTarget.event, inputTarget.window, inputTarget.client) } else {
                inputController.handleInputEvent(
                    inputTarget.event,
                    window: inputTarget.window,
                    deferredInjectionValidator: { [weak self] in
                        guard let self else { return false }
                        guard self.streamRegistry.isInputSessionActive(sessionID, clientID: client.id) else {
                            return false
                        }
                        return self.inputStreamCache.entry(for: inputMessage.streamID) != nil
                    }
                )
            }
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to decode input event: ")
        }
    }

}
#endif
