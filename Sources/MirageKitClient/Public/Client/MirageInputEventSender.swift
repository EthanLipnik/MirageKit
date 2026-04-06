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

public final class MirageInputEventSender: @unchecked Sendable {
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

    /// Whether a continuous-event drain is already scheduled.
    /// Accessed only on `sendQueue`.
    private var sendInFlight = false

    /// Latest continuous event waiting to send (pointer move/drag, scroll changed).
    /// Replaced on each arrival — only the newest matters.
    /// Accessed only on `sendQueue`.
    private var pendingContinuousData: Data?

    func updateSendHandler(_ handler: (@Sendable (Data, Bool) async throws -> Void)?) {
        connectionLock.lock()
        sendHandler = handler
        connectionLock.unlock()

        if handler == nil {
            sendQueue.async { [weak self] in
                self?.sendInFlight = false
                self?.pendingContinuousData = nil
            }
        }
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

    public func sendInputFireAndForget(_ event: MirageInputEvent, streamID: StreamID) {
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

        let continuous = isContinuousEvent(event)

        sendQueue.async { [weak self] in
            guard let self else { return }

            if continuous {
                // Coalesce: replace any pending continuous event with the latest.
                self.pendingContinuousData = data
                self.scheduleDrain()
            } else {
                // Discrete events send immediately — reliability is handled by the transport.
                self.fireAndForgetSend(data)
            }
        }
    }

    // MARK: - Non-Blocking Send

    /// Sends data immediately without awaiting completion.
    private func fireAndForgetSend(_ data: Data) {
        guard let handler = currentSendHandler() else { return }
        Task {
            try? await handler(data, false)
        }
    }

    /// Schedules a drain of the pending continuous event on the next run loop tick.
    /// This naturally coalesces rapid mouse moves into one send per tick.
    private func scheduleDrain() {
        guard !sendInFlight else { return }
        sendInFlight = true
        sendQueue.async { [weak self] in
            guard let self else { return }
            self.sendInFlight = false
            if let continuous = self.pendingContinuousData {
                self.pendingContinuousData = nil
                self.fireAndForgetSend(continuous)
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

    private func isContinuousEvent(_ event: MirageInputEvent) -> Bool {
        switch event {
        case .mouseMoved, .mouseDragged, .rightMouseDragged, .otherMouseDragged:
            return true
        case let .scrollWheel(e):
            let isBoundary = e.phase == .began || e.phase == .ended || e.phase == .cancelled
                || e.momentumPhase == .began || e.momentumPhase == .ended || e.momentumPhase == .cancelled
            return !isBoundary
        default:
            return false
        }
    }

    private func isPointerMoveOrDragEvent(_ event: MirageInputEvent) -> Bool {
        switch event {
        case .mouseMoved, .mouseDragged, .rightMouseDragged, .otherMouseDragged:
            true
        default:
            false
        }
    }
}
