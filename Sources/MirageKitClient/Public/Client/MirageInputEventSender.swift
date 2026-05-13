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

/// Serializes client input events and applies bounded coalescing before they enter the control channel.
public final class MirageInputEventSender: @unchecked Sendable {
    /// Transport reliability requested for a serialized input payload.
    enum DeliveryMode: Equatable {
        case reliable
        case orderedBestEffort
        case droppableRealtime
    }

    /// Per-stream throttle window used while a window stream is settling after startup or resize.
    private struct TemporaryPointerCoalescingState {
        var deadline: CFAbsoluteTime = 0
        var lastForwardedPointerTimestamp: CFAbsoluteTime = 0
    }

    /// Input event waiting for the non-blocking send queue.
    private struct PendingInput {
        let event: MirageInputEvent
        let streamID: StreamID
    }

    /// Continuous event categories that can be replaced by newer work without changing user intent.
    private enum ReplaceableContinuousInputKind: Equatable {
        case mouseMoved
        case mouseDragged
        case rightMouseDragged
        case otherMouseDragged
        case scrollWheel
        case stylusHover
    }

    private static let keyboardDiagnosticRateLimiter = MirageKeyboardInputDiagnosticRateLimiter()
    private static let maxPendingInputs = 256
    private static let maxPendingContactSamples = 4096

    private let sendQueue = DispatchQueue(label: "com.mirage.client.input-send", qos: .userInteractive)
    private let connectionLock = NSLock()
    private var sendHandler: (@Sendable (Data, DeliveryMode) async throws -> Void)?
    private let pointerCoalescingLock = NSLock()
    private var temporaryPointerCoalescingByStreamID: [StreamID: TemporaryPointerCoalescingState] = [:]
    private let interactionLock = NSLock()
    private var lastInteractionTime: CFAbsoluteTime = 0

    /// Whether a continuous-event drain is already scheduled.
    /// Accessed only on `sendQueue`.
    private var sendInFlight = false

    /// Pending best-effort input work waiting behind the active send.
    /// Discrete events stay ordered; replaceable high-rate work is bounded.
    /// Accessed only on `sendQueue`.
    private var pendingInputs: [PendingInput] = []

    func updateSendHandler(_ handler: (@Sendable (Data, DeliveryMode) async throws -> Void)?) {
        connectionLock.lock()
        sendHandler = handler
        connectionLock.unlock()

        if handler == nil {
            sendQueue.async { [weak self] in
                self?.sendInFlight = false
                self?.pendingInputs.removeAll()
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
        defer { pointerCoalescingLock.unlock() }
        var state = temporaryPointerCoalescingByStreamID[streamID] ?? TemporaryPointerCoalescingState()
        state.deadline = max(state.deadline, now + clampedDuration)
        temporaryPointerCoalescingByStreamID[streamID] = state
    }

    func clearTemporaryPointerCoalescing(for streamID: StreamID) {
        pointerCoalescingLock.lock()
        defer { pointerCoalescingLock.unlock() }
        temporaryPointerCoalescingByStreamID.removeValue(forKey: streamID)
    }

    func sendInput(_ event: MirageInputEvent, streamID: StreamID) async throws {
        recordInteractionIfNeeded(event)
        if shouldDropInputForTemporaryCoalescing(event, streamID: streamID) {
            return
        }
        Self.logKeyboardDiagnosticIfNeeded(
            event,
            streamID: streamID,
            deliveryMode: .reliable,
            path: "client_send_reliable"
        )
        let data = try makeInputMessageData(event: event, streamID: streamID)
        if let sendHandler = currentSendHandler {
            try await sendHandler(data, .reliable)
            return
        }
        throw MirageError.protocolError("Not connected")
    }

    /// Enqueues an input event for best-effort delivery without blocking the caller.
    public func sendInputFireAndForget(_ event: MirageInputEvent, streamID: StreamID) {
        recordInteractionIfNeeded(event)
        if shouldDropInputForTemporaryCoalescing(event, streamID: streamID) {
            return
        }
        Self.logKeyboardDiagnosticIfNeeded(
            event,
            streamID: streamID,
            deliveryMode: Self.deliveryMode(for: event),
            path: "client_send_best_effort_enqueue"
        )

        sendQueue.async { [weak self] in
            guard let self else { return }

            guard currentSendHandler != nil else {
                pendingInputs.removeAll()
                return
            }

            appendPendingInput(PendingInput(event: event, streamID: streamID))
            trimPendingInputs()
            scheduleDrain()
        }
    }

    // MARK: - Non-Blocking Send

    private func appendPendingInput(_ pending: PendingInput) {
        if let last = pendingInputs.last,
           last.streamID == pending.streamID,
           let mergedEvent = last.event.mergedWithCompatibleNativeContinuousScrollEvent(pending.event) {
            pendingInputs[pendingInputs.count - 1] = PendingInput(event: mergedEvent, streamID: pending.streamID)
            return
        }

        if pending.event.hasNativeScrollMetadata {
            pendingInputs.append(pending)
            return
        }

        if let kind = replaceableContinuousKind(for: pending.event),
           let last = pendingInputs.last,
           last.streamID == pending.streamID,
           !last.event.hasNativeScrollMetadata,
           replaceableContinuousKind(for: last.event) == kind {
            pendingInputs[pendingInputs.count - 1] = pending
            return
        }

        pendingInputs.append(pending)
    }

    /// Schedules one best-effort send at a time.
    private func scheduleDrain() {
        guard !sendInFlight else { return }
        guard !pendingInputs.isEmpty else { return }
        guard let handler = currentSendHandler else {
            pendingInputs.removeAll()
            return
        }

        let pending = pendingInputs.removeFirst()
        sendInFlight = true

        Task { [weak self] in
            guard let self else { return }
            do {
                let data = try makeInputMessageData(event: pending.event, streamID: pending.streamID)
                try await handler(data, Self.deliveryMode(for: pending.event))
            } catch {
                if Self.isExpectedBestEffortSendFailure(error) {
                    MirageLogger.client("Dropped best-effort input because the stream closed: \(error.localizedDescription)")
                } else {
                    MirageLogger.error(.client, error: error, message: "Failed to send input: ")
                }
            }

            sendQueue.async { [weak self] in
                guard let self else { return }
                sendInFlight = false
                scheduleDrain()
            }
        }
    }

    private func trimPendingInputs() {
        while pendingInputs.count > Self.maxPendingInputs {
            if removeFirstPendingInput(where: { replaceableContinuousKind(for: $0.event) != nil }) { continue }
            if removeFirstPendingInput(where: { isDroppableContactMove($0.event) }) { continue }
            break
        }

        while pendingInputs.reduce(into: 0, { result, input in
            guard case let .pointerSampleBatch(batch) = input.event,
                  batch.phase == .moved else {
                return
            }
            result += batch.samples.count
        }) > Self.maxPendingContactSamples {
            if removeFirstPendingInput(where: { isDroppableContactMove($0.event) }) { continue }
            break
        }
    }

    private func removeFirstPendingInput(where shouldRemove: (PendingInput) -> Bool) -> Bool {
        guard let index = pendingInputs.firstIndex(where: shouldRemove) else { return false }
        pendingInputs.remove(at: index)
        return true
    }

    private func makeInputMessageData(event: MirageInputEvent, streamID: StreamID) throws -> Data {
        let inputMessage = InputEventMessage(streamID: streamID, event: event)
        let message = try ControlMessage(type: .inputEvent, payload: inputMessage.serializePayload())
        return message.serialize()
    }

    private static func isExpectedBestEffortSendFailure(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        let nsError = error as NSError
        if nsError.domain == "Loom.LoomError" {
            return nsError.code == 0 || nsError.code == 3
        }
        if nsError.domain == NSPOSIXErrorDomain {
            return [32, 54, 57, 89].contains(nsError.code)
        }
        return false
    }

    /// Current transport send closure protected by the sender connection lock.
    private var currentSendHandler: (@Sendable (Data, DeliveryMode) async throws -> Void)? {
        connectionLock.lock()
        defer { connectionLock.unlock() }
        return sendHandler
    }

    /// Returns the elapsed time since the last user interaction observed by this sender.
    public func secondsSinceLastInteraction(now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> CFAbsoluteTime? {
        interactionLock.lock()
        defer { interactionLock.unlock() }
        let lastInteractionTimestamp = lastInteractionTime
        guard lastInteractionTimestamp > 0 else { return nil }
        return max(0, now - lastInteractionTimestamp)
    }

    /// Returns whether this sender observed an interaction inside the supplied duration.
    public func hasRecentInteraction(
        within duration: CFAbsoluteTime,
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) -> Bool {
        guard let elapsed = secondsSinceLastInteraction(now: now) else { return false }
        return elapsed < duration
    }

    func shouldDropInputForTemporaryCoalescing(
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
        case .mouseMoved, .mouseDragged, .rightMouseDragged, .otherMouseDragged:
            true
        case let .pointerSampleBatch(batch):
            batch.isHover
        default:
            false
        }
    }

    private func replaceableContinuousKind(for event: MirageInputEvent) -> ReplaceableContinuousInputKind? {
        switch event {
        case .mouseMoved:
            .mouseMoved
        case .mouseDragged:
            .mouseDragged
        case .rightMouseDragged:
            .rightMouseDragged
        case .otherMouseDragged:
            .otherMouseDragged
        case let .scrollWheel(e):
            e.isBoundaryScrollEvent ? nil : .scrollWheel
        case let .pointerSampleBatch(batch):
            batch.isHover ? .stylusHover : nil
        default:
            nil
        }
    }

    private func isDroppableContactMove(_ event: MirageInputEvent) -> Bool {
        guard case let .pointerSampleBatch(batch) = event else { return false }
        return batch.phase == .moved
    }

    private static func deliveryMode(for event: MirageInputEvent) -> DeliveryMode {
        switch event {
        case .mouseMoved,
             .mouseDragged,
             .rightMouseDragged,
             .otherMouseDragged:
            .droppableRealtime
        case let .pointerSampleBatch(batch) where batch.phase == .hover:
            .droppableRealtime
        default:
            .orderedBestEffort
        }
    }

    private static func logKeyboardDiagnosticIfNeeded(
        _ event: MirageInputEvent,
        streamID: StreamID,
        deliveryMode: DeliveryMode,
        path: String
    ) {
        guard let diagnostic = MirageKeyboardInputDiagnostics.diagnosticEvent(for: event) else {
            return
        }
        let rateLimitKey = "client:\(path):\(streamID):\(diagnostic.rateLimitKey)"
        guard keyboardDiagnosticRateLimiter.shouldLog(key: rateLimitKey) else {
            return
        }
        MirageLogger.client(
            "Keyboard input send: stream=\(streamID), kind=\(diagnostic.kind), " +
                "key=\(diagnostic.keyCodeCategory), delivery=\(deliveryMode), path=\(path)"
        )
    }

    func recordInteractionIfNeeded(
        _ event: MirageInputEvent,
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) {
        guard event.shouldGateAutomaticProbe else { return }
        interactionLock.lock()
        defer { interactionLock.unlock() }
        lastInteractionTime = now
    }
}
