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
import Network

final class MirageInputEventSender: @unchecked Sendable {
    private struct TemporaryPointerCoalescingState {
        var deadline: CFAbsoluteTime = 0
        var lastForwardedPointerTimestamp: CFAbsoluteTime = 0
    }

    private static let pointerCoalescingMinInterval: CFAbsoluteTime = 1.0 / 60.0

    private let sendQueue = DispatchQueue(label: "com.mirage.client.input-send", qos: .userInteractive)
    private let connectionLock = NSLock()
    private var controlConnection: NWConnection?
    private let pointerCoalescingLock = NSLock()
    private var temporaryPointerCoalescingByStreamID: [StreamID: TemporaryPointerCoalescingState] = [:]

    func updateConnection(_ connection: NWConnection?) {
        connectionLock.lock()
        controlConnection = connection
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
        let connection = try currentConnectionOrThrow()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sendQueue.async {
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                })
            }
        }
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
            guard let self, let connection = self.currentConnection() else { return }
            connection.send(content: data, completion: .idempotent)
        }
    }

    private func makeInputMessageData(event: MirageInputEvent, streamID: StreamID) throws -> Data {
        let inputMessage = InputEventMessage(streamID: streamID, event: event)
        let message = try ControlMessage(type: .inputEvent, payload: inputMessage.serializePayload())
        return message.serialize()
    }

    private func currentConnection() -> NWConnection? {
        connectionLock.lock()
        let connection = controlConnection
        connectionLock.unlock()
        return connection
    }

    private func currentConnectionOrThrow() throws -> NWConnection {
        guard let connection = currentConnection() else {
            throw MirageError.protocolError("Not connected")
        }
        return connection
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
