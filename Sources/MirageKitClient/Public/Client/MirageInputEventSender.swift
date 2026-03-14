//
//  MirageInputEventSender.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/4/26.
//
//  Dedicated input-event send path that stays off MainActor.
//

import Foundation
import MirageKit

final class MirageInputEventSender: @unchecked Sendable {
    private struct TemporaryPointerCoalescingState {
        var deadline: CFAbsoluteTime = 0
        var lastForwardedPointerTimestamp: CFAbsoluteTime = 0
    }

    private static let pointerCoalescingMinInterval: CFAbsoluteTime = 1.0 / 60.0

    private let sendQueue = DispatchQueue(label: "com.mirage.client.input-send", qos: .userInteractive)
    private let connectionLock = NSLock()
    private var sendHandler: (@Sendable (Data, Bool) async throws -> Void)?
    private let pointerCoalescingLock = NSLock()
    private var temporaryPointerCoalescingByStreamID: [StreamID: TemporaryPointerCoalescingState] = [:]

    func updateSendHandler(_ handler: (@Sendable (Data, Bool) async throws -> Void)?) {
        connectionLock.lock()
        sendHandler = handler
        connectionLock.unlock()
    }

    func activateTemporaryPointerCoalescing(
        for streamID: StreamID,
        duration: CFAbsoluteTime = 1.2,
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) {
        let clampedDuration = max(0, duration)
        pointerCoalescingLock.lock()
        var state = temporaryPointerCoalescingByStreamID[streamID] ?? TemporaryPointerCoalescingState()
        state.deadline = max(state.deadline, now + clampedDuration)
        temporaryPointerCoalescingByStreamID[streamID] = state
        pointerCoalescingLock.unlock()
    }

    func clearTemporaryPointerCoalescing(for streamID: StreamID) {
        pointerCoalescingLock.lock()
        temporaryPointerCoalescingByStreamID.removeValue(forKey: streamID)
        pointerCoalescingLock.unlock()
    }

    func sendInput(_ event: MirageInputEvent, streamID: StreamID) async throws {
        if shouldDropInputForTemporaryCoalescing(event, streamID: streamID) {
            return
        }
        let data = try makeInputMessageData(event: event, streamID: streamID)
        if let sendHandler = currentSendHandler() {
            try await sendHandler(data, true)
            return
        }
        throw MirageError.protocolError("Not connected")
    }

    func sendInputFireAndForget(_ event: MirageInputEvent, streamID: StreamID) {
        if shouldDropInputForTemporaryCoalescing(event, streamID: streamID) {
            return
        }

        let data: Data
        do {
            data = try makeInputMessageData(event: event, streamID: streamID)
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to encode input: ")
            return
        }

        sendQueue.async { [weak self] in
            guard let self else { return }
            if let sendHandler = self.currentSendHandler() {
                Task {
                    try? await sendHandler(data, false)
                }
            }
        }
    }

    private func makeInputMessageData(event: MirageInputEvent, streamID: StreamID) throws -> Data {
        let inputMessage = InputEventMessage(streamID: streamID, event: event)
        let message = try ControlMessage(type: .inputEvent, payload: inputMessage.serializePayload())
        return message.serialize()
    }

    private func currentSendHandler() -> (@Sendable (Data, Bool) async throws -> Void)? {
        connectionLock.lock()
        let handler = sendHandler
        connectionLock.unlock()
        return handler
    }

    func shouldDropInputForTemporaryCoalescingForTesting(
        _ event: MirageInputEvent,
        streamID: StreamID,
        now: CFAbsoluteTime,
        minInterval: CFAbsoluteTime = 1.0 / 60.0
    ) -> Bool {
        shouldDropInputForTemporaryCoalescing(
            event,
            streamID: streamID,
            now: now,
            minInterval: minInterval
        )
    }

    private func shouldDropInputForTemporaryCoalescing(
        _ event: MirageInputEvent,
        streamID: StreamID,
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent(),
        minInterval: CFAbsoluteTime = 1.0 / 60.0
    ) -> Bool {
        guard isPointerMoveOrDragEvent(event) else { return false }

        pointerCoalescingLock.lock()
        defer { pointerCoalescingLock.unlock() }
        guard var state = temporaryPointerCoalescingByStreamID[streamID] else { return false }

        if now > state.deadline {
            temporaryPointerCoalescingByStreamID.removeValue(forKey: streamID)
            return false
        }

        if state.lastForwardedPointerTimestamp > 0,
           now - state.lastForwardedPointerTimestamp < minInterval {
            temporaryPointerCoalescingByStreamID[streamID] = state
            return true
        }

        state.lastForwardedPointerTimestamp = now
        temporaryPointerCoalescingByStreamID[streamID] = state
        return false
    }

    private func isPointerMoveOrDragEvent(_ event: MirageInputEvent) -> Bool {
        switch event {
        case .mouseMoved,
             .mouseDragged,
             .rightMouseDragged,
             .otherMouseDragged:
            true
        default:
            false
        }
    }
}
