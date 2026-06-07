//
//  MirageHostService+InputFast.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Fast input path handling.
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
import CoreGraphics
import Foundation

#if os(macOS)
extension MirageHostService {
    /// Fast input event handler - runs on inputQueue, NOT MainActor.
    nonisolated func handleInputEventFast(
        _ message: MirageWire.ControlMessage,
        from client: MirageConnectedClient,
        sessionID: UUID
    ) {
        let sessionActive = streamRegistry.isInputSessionActive(sessionID, clientID: client.id)
        guard sessionActive else { return }

        do {
            let inputMessage = try MirageWire.InputEventMessage.deserializePayload(message.payload)
            HostKeyboardInputDiagnostics.logReceive(
                event: inputMessage.event,
                streamID: inputMessage.streamID,
                sessionActive: sessionActive,
                path: "input_fast"
            )
            let inputStreamID = inputMessage.streamID
            dispatchMainWork { [weak self] in
                guard let self,
                      let streamContext = self.streamsByID[inputStreamID] else {
                    return
                }
                await streamContext.noteClientInput()
            }

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
            logAppPointerTargetResolutionIfNeeded(
                streamID: inputMessage.streamID,
                originalEvent: inputMessage.event,
                routedEvent: inputTarget.event,
                window: inputTarget.window
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

            if let handler = onInputEvent {
                handler(inputTarget.event, inputTarget.window, inputTarget.client)
            } else {
                let inputBackend = platformInputInjectionBackend
                let streamRegistry = streamRegistry
                let inputStreamCache = inputStreamCache
                let inputStreamID = inputMessage.streamID
                let clientID = client.id
                Task(priority: .userInitiated) {
                    do {
                        try await inputBackend.inject(
                            inputTarget.event,
                            target: .window(inputTarget.window),
                            deferredInjectionValidator: {
                                guard streamRegistry.isInputSessionActive(sessionID, clientID: clientID) else {
                                    return false
                                }
                                return inputStreamCache.entry(for: inputStreamID) != nil
                            }
                        )
                    } catch {
                        MirageLogger.error(.host, error: error, message: "Failed to inject input event: ")
                    }
                }
            }
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to decode input event: ")
        }
    }

}

private extension MirageHostService {
    nonisolated func logAppPointerTargetResolutionIfNeeded(
        streamID: StreamID,
        originalEvent: MirageInput.MirageInputEvent,
        routedEvent: MirageInput.MirageInputEvent,
        window: MirageMedia.MirageWindow
    ) {
        guard window.id != 0,
              let routedPointer = AppPointerTargetDiagnostic(event: routedEvent) else {
            return
        }

        let originalPointer = AppPointerTargetDiagnostic(event: originalEvent)
        let originalLocationText = originalPointer.map { pointer in
            " originalLocation=\(Self.formattedNormalizedPoint(pointer.location))"
        } ?? ""
        MirageLogger.host(
            "App pointer target stream=\(streamID) event=\(routedPointer.eventName) " +
                "window=\(window.id) location=\(Self.formattedNormalizedPoint(routedPointer.location))" +
                originalLocationText +
                " frame=\(Self.formattedRect(window.frame)) clickCount=\(routedPointer.clickCount)"
        )
    }

    nonisolated static func formattedNormalizedPoint(_ point: CGPoint) -> String {
        "(\(String(format: "%.3f", point.x)),\(String(format: "%.3f", point.y)))"
    }

    nonisolated static func formattedRect(_ rect: CGRect) -> String {
        "(\(Int(rect.origin.x)),\(Int(rect.origin.y)),\(Int(rect.width))x\(Int(rect.height)))"
    }
}

private struct AppPointerTargetDiagnostic {
    let eventName: String
    let location: CGPoint
    let clickCount: Int

    init?(event: MirageInput.MirageInputEvent) {
        switch event {
        case let .mouseDown(event):
            self.init(eventName: "mouseDown", event: event)
        case let .mouseUp(event):
            self.init(eventName: "mouseUp", event: event)
        case let .rightMouseDown(event):
            self.init(eventName: "rightMouseDown", event: event)
        case let .rightMouseUp(event):
            self.init(eventName: "rightMouseUp", event: event)
        case let .otherMouseDown(event):
            self.init(eventName: "otherMouseDown", event: event)
        case let .otherMouseUp(event):
            self.init(eventName: "otherMouseUp", event: event)
        case let .pointerSampleBatch(batch) where batch.phase == .began || batch.phase == .ended || batch.phase == .cancelled:
            guard let location = batch.lastLocation else { return nil }
            self.init(
                eventName: "pointerSampleBatch.\(batch.phase.rawValue)",
                location: location,
                clickCount: batch.clickCount
            )
        default:
            return nil
        }
    }

    private init(eventName: String, event: MirageInput.MirageMouseEvent) {
        self.init(eventName: eventName, location: event.location, clickCount: event.clickCount)
    }

    private init(eventName: String, location: CGPoint, clickCount: Int) {
        self.eventName = eventName
        self.location = location
        self.clickCount = clickCount
    }
}
#endif
