//
//  MirageInputEventSender.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/4/26.
//
//  Dedicated input-event send path that stays off MainActor.
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

/// Serializes client input events and applies bounded coalescing before they enter the control channel.
public final class MirageInputEventSender: @unchecked Sendable {
    /// Transport reliability requested for a serialized input payload.
    enum DeliveryMode: Equatable {
        case reliable
        case orderedBestEffort
        case droppableRealtime
    }

    /// Input work waiting for the non-blocking control-channel fallback queue.
    private enum PendingInput {
        case event(MirageInput.MirageInputEvent, streamID: StreamID)
        case continuousBatch(MirageInput.MirageContinuousInputBatch)

        var event: MirageInput.MirageInputEvent? {
            guard case let .event(event, _) = self else { return nil }
            return event
        }

        var streamID: StreamID {
            switch self {
            case let .event(_, streamID):
                streamID
            case let .continuousBatch(batch):
                batch.streamID
            }
        }
    }

    /// Continuous event categories that can be replaced by newer work without changing user intent.
    private enum ReplaceableContinuousInputKind: Hashable {
        case mouseMoved
        case mouseDragged
        case rightMouseDragged
        case otherMouseDragged
        case scrollWheel
        case stylusHover
    }

    private struct PendingRealtimeInputKey: Hashable {
        let streamID: StreamID
        let kind: ReplaceableContinuousInputKind
    }

    private static let keyboardDiagnosticRateLimiter = MirageKeyboardInputDiagnosticRateLimiter()
    private static let maxPendingInputs = 256

    private let sendQueue = DispatchQueue(label: "com.mirage.client.input-send", qos: .userInteractive)
    private let connectionLock = NSLock()
    private var sendHandler: (@Sendable (Data, DeliveryMode) async throws -> Void)?
    private var priorityRoute: MiragePriorityInputClientRoute?
    private let interactionLock = NSLock()
    private var lastInteractionTime: CFAbsoluteTime = 0

    /// Whether a continuous-event drain is already scheduled.
    /// Accessed only on `sendQueue`.
    private var sendInFlight = false

    /// Pending control-channel fallback work waiting behind the active send.
    /// Discrete events stay ordered; compact continuous batches stay bounded.
    /// Accessed only on `sendQueue`.
    private var pendingInputs: [PendingInput] = []
    private let continuousInputBatcher = MirageContinuousInputBatcher()
    private var continuousFlushScheduled = false
    private var nextContinuousBatchSequence: UInt64 = 1
    private var nextContinuousFallbackEventID: UInt64 = 1 << 63

    func updateSendHandler(_ handler: (@Sendable (Data, DeliveryMode) async throws -> Void)?) {
        connectionLock.lock()
        sendHandler = handler
        connectionLock.unlock()

        if handler == nil {
            sendQueue.async { [weak self] in
                self?.sendInFlight = false
                self?.pendingInputs.removeAll()
                self?.continuousInputBatcher.removeAll()
                self?.continuousFlushScheduled = false
            }
        }
    }

    func updatePriorityRoute(_ route: MiragePriorityInputClientRoute?) {
        connectionLock.lock()
        let previousRoute = priorityRoute
        priorityRoute = route
        connectionLock.unlock()

        previousRoute?.stop()
    }

    func priorityInputSnapshot() -> MiragePriorityInputClientMetricsSnapshot? {
        currentPriorityRoute?.snapshot()
    }

    func sendInput(_ event: MirageInput.MirageInputEvent, streamID: StreamID) async throws {
        flushContinuousInputSynchronously(reason: "syncBoundary")
        recordInteractionIfNeeded(event)
        MirageInputLatencyTelemetry.shared.recordClientCapture(event: event, streamID: streamID)
        Self.logKeyboardDiagnosticIfNeeded(
            event,
            streamID: streamID,
            deliveryMode: .reliable,
            path: "client_send_reliable"
        )
        let data = try makeInputMessageData(event: event, streamID: streamID)
        if let sendHandler = currentSendHandler {
            MirageInputLatencyTelemetry.shared.recordClientSend(event: event, streamID: streamID)
            MirageInputLatencyTelemetry.shared.recordClientRoute(
                event: event,
                streamID: streamID,
                route: .reliable
            )
            try await sendHandler(data, .reliable)
            return
        }
        throw MirageCore.MirageError.protocolError("Not connected")
    }

    /// Enqueues an input event for best-effort delivery without blocking the caller.
    public func sendInputFireAndForget(_ event: MirageInput.MirageInputEvent, streamID: StreamID) {
        recordInteractionIfNeeded(event)
        MirageInputLatencyTelemetry.shared.recordClientCapture(event: event, streamID: streamID)
        Self.logKeyboardDiagnosticIfNeeded(
            event,
            streamID: streamID,
            deliveryMode: Self.deliveryMode(for: event),
            path: "client_send_best_effort_enqueue"
        )

        sendQueue.async { [weak self] in
            guard let self else { return }

            guard currentSendHandler != nil || currentPriorityRoute != nil else {
                pendingInputs.removeAll()
                continuousInputBatcher.removeAll()
                return
            }

            if continuousInputBatcher.enqueue(event, streamID: streamID) {
                if continuousInputBatcher.hasFullPacket {
                    flushContinuousInputsLocked(reason: "fullPacket")
                } else {
                    scheduleContinuousFlushLocked()
                }
                return
            }

            flushContinuousInputsLocked(reason: "orderedBoundary")
            appendPendingInput(.event(event, streamID: streamID))
            compactPendingRealtimeInputs()
            trimPendingInputs()
            scheduleDrain()
        }
    }

    private func flushContinuousInputSynchronously(reason: String) {
        sendQueue.sync {
            flushContinuousInputsLocked(reason: reason)
        }
    }

    private func scheduleContinuousFlushLocked() {
        guard !continuousFlushScheduled else { return }
        continuousFlushScheduled = true
        let scheduledAt = Date.timeIntervalSinceReferenceDate
        sendQueue.asyncAfter(deadline: .now() + .milliseconds(1)) { [weak self] in
            guard let self else { return }
            continuousFlushScheduled = false
            flushContinuousInputsLocked(reason: "timer", scheduledAt: scheduledAt)
        }
    }

    private func flushContinuousInputsLocked(
        reason: String,
        scheduledAt: TimeInterval? = nil
    ) {
        continuousFlushScheduled = false
        let batches = continuousInputBatcher.flush()
        guard !batches.isEmpty else { return }

        for batch in batches {
            let sequencedBatch = batch.withSequence(nextContinuousBatchSequenceLocked())
            MirageInputLatencyTelemetry.shared.recordClientContinuousBatchFlush(
                sequencedBatch,
                reason: reason,
                scheduledAt: scheduledAt
            )
            sendOrEnqueueContinuousBatchLocked(sequencedBatch)
        }
    }

    private func sendOrEnqueueContinuousBatchLocked(_ batch: MirageInput.MirageContinuousInputBatch) {
        if let route = currentPriorityRoute {
            do {
                recordContinuousBatchClientSend(batch, route: .priorityContinuousBatch)
                try route.sendContinuousBatch(batch)
            } catch {
                MirageLogger.error(.client, error: error, message: "Failed to send continuous priority input: ")
                appendPendingInput(.continuousBatch(batch))
                trimPendingInputs()
                scheduleDrain()
            }
            return
        }

        guard currentSendHandler != nil else { return }
        appendPendingInput(.continuousBatch(batch))
        trimPendingInputs()
        scheduleDrain()
    }

    // MARK: - Non-Blocking Send

    private func appendPendingInput(_ pending: PendingInput) {
        guard case let .event(pendingEvent, pendingStreamID) = pending else {
            pendingInputs.append(pending)
            return
        }

        if let last = pendingInputs.last,
           case let .event(lastEvent, lastStreamID) = last,
           lastStreamID == pendingStreamID,
           let mergedEvent = lastEvent.mergedWithCompatibleNativeContinuousScrollEvent(pendingEvent) {
            pendingInputs[pendingInputs.count - 1] = .event(mergedEvent, streamID: pendingStreamID)
            return
        }

        if pendingEvent.hasNativeScrollMetadata {
            pendingInputs.append(pending)
            return
        }

        if let kind = replaceableContinuousKind(for: pendingEvent),
           let last = pendingInputs.last,
           case let .event(lastEvent, lastStreamID) = last,
           lastStreamID == pendingStreamID,
           !lastEvent.hasNativeScrollMetadata,
           replaceableContinuousKind(for: lastEvent) == kind {
            pendingInputs[pendingInputs.count - 1] = pending
            return
        }

        pendingInputs.append(pending)
    }

    private func compactPendingRealtimeInputs() {
        guard pendingInputs.count > 1 else { return }

        var compactedInputs: [PendingInput] = []
        var latestIndexByKey: [PendingRealtimeInputKey: Int] = [:]

        for pendingInput in pendingInputs {
            guard case let .event(event, streamID) = pendingInput,
                  let kind = droppableRealtimeKind(for: event) else {
                compactedInputs.append(pendingInput)
                latestIndexByKey.removeAll(keepingCapacity: true)
                continue
            }

            let key = PendingRealtimeInputKey(streamID: streamID, kind: kind)
            if let existingIndex = latestIndexByKey[key] {
                compactedInputs.remove(at: existingIndex)
                for indexedKey in Array(latestIndexByKey.keys) {
                    guard let index = latestIndexByKey[indexedKey], index > existingIndex else {
                        continue
                    }
                    latestIndexByKey[indexedKey] = index - 1
                }
            }

            latestIndexByKey[key] = compactedInputs.count
            compactedInputs.append(pendingInput)
        }

        pendingInputs = compactedInputs
    }

    /// Schedules one best-effort send at a time.
    private func scheduleDrain() {
        guard !sendInFlight else { return }
        guard !pendingInputs.isEmpty else { return }
        let handler = currentSendHandler
        let route = currentPriorityRoute
        guard handler != nil || route != nil else {
            pendingInputs.removeAll()
            return
        }

        let pending = pendingInputs.removeFirst()
        sendInFlight = true

        Task { [weak self] in
            guard let self else { return }
            do {
                switch pending {
                case let .event(event, streamID):
                    let deliveryMode = Self.deliveryMode(for: event)
                    MirageInputLatencyTelemetry.shared.recordClientSend(event: event, streamID: streamID)
                    if let route {
                        try await route.send(event: event, streamID: streamID, deliveryMode: deliveryMode)
                    } else if let handler {
                        let data = try makeInputMessageData(event: event, streamID: streamID)
                        MirageInputLatencyTelemetry.shared.recordClientRoute(
                            event: event,
                            streamID: streamID,
                            route: .orderedBestEffort
                        )
                        try await handler(data, deliveryMode)
                    }
                case let .continuousBatch(batch):
                    guard let handler else { return }
                    let data = try makeContinuousInputFallbackData(batch: batch)
                    recordContinuousBatchClientSend(batch, route: .priorityFallback)
                    try await handler(data, .droppableRealtime)
                }
            } catch {
                if MirageConnectionErrorClassifier.isExpectedBestEffortInputSendFailure(error) {
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
            if removeFirstPendingInput(where: { pending in
                guard case let .event(event, _) = pending else { return false }
                return replaceableContinuousKind(for: event) != nil
            }) { continue }
            if removeFirstPendingInput(where: { pending in
                guard case let .event(event, _) = pending else { return false }
                return isDroppablePointerMovement(event)
            }) { continue }
            if removeFirstPendingInput(where: { pending in
                guard case let .continuousBatch(batch) = pending else { return false }
                return !batch.isPencilContactBatch
            }) { continue }
            break
        }
    }

    private func removeFirstPendingInput(where shouldRemove: (PendingInput) -> Bool) -> Bool {
        guard let index = pendingInputs.firstIndex(where: shouldRemove) else { return false }
        pendingInputs.remove(at: index)
        return true
    }

    private func makeInputMessageData(event: MirageInput.MirageInputEvent, streamID: StreamID) throws -> Data {
        let inputMessage = MirageWire.InputEventMessage(streamID: streamID, event: event)
        let message = try MirageWire.ControlMessage(type: .inputEvent, payload: inputMessage.serializePayload())
        return message.serialize()
    }

    private func makeContinuousInputFallbackData(batch: MirageInput.MirageContinuousInputBatch) throws -> Data {
        let envelope = MirageWire.MiragePriorityInputEnvelope(
            kind: .continuousInput,
            eventID: nextContinuousFallbackEventIDLocked(),
            streamID: batch.streamID,
            deliveryClass: .realtime,
            sentAtUptime: ProcessInfo.processInfo.systemUptime,
            inputPayload: try batch.serialize()
        )
        let message = try MirageWire.ControlMessage(type: .priorityInputEvent, payload: envelope.serialize())
        return message.serialize()
    }

    private func nextContinuousBatchSequenceLocked() -> UInt64 {
        let sequence = nextContinuousBatchSequence
        nextContinuousBatchSequence &+= 1
        if nextContinuousBatchSequence == 0 {
            nextContinuousBatchSequence = 1
        }
        return sequence
    }

    private func nextContinuousFallbackEventIDLocked() -> UInt64 {
        let eventID = nextContinuousFallbackEventID
        nextContinuousFallbackEventID &+= 1
        if nextContinuousFallbackEventID == 0 {
            nextContinuousFallbackEventID = 1 << 63
        }
        return eventID
    }

    private func recordContinuousBatchClientSend(
        _ batch: MirageInput.MirageContinuousInputBatch,
        route: MirageInputLatencyClientRoute
    ) {
        for event in batch.inputEvents() {
            MirageInputLatencyTelemetry.shared.recordClientSend(event: event, streamID: batch.streamID)
            MirageInputLatencyTelemetry.shared.recordClientRoute(
                event: event,
                streamID: batch.streamID,
                route: route
            )
        }
    }

    /// Current transport send closure protected by the sender connection lock.
    private var currentSendHandler: (@Sendable (Data, DeliveryMode) async throws -> Void)? {
        connectionLock.lock()
        defer { connectionLock.unlock() }
        return sendHandler
    }

    private var currentPriorityRoute: MiragePriorityInputClientRoute? {
        connectionLock.lock()
        defer { connectionLock.unlock() }
        return priorityRoute
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

    private func replaceableContinuousKind(for event: MirageInput.MirageInputEvent) -> ReplaceableContinuousInputKind? {
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
        case let .pointerSampleBatch(batch) where batch.phase == .hover:
            .stylusHover
        default:
            nil
        }
    }

    private func droppableRealtimeKind(for event: MirageInput.MirageInputEvent) -> ReplaceableContinuousInputKind? {
        guard Self.deliveryMode(for: event) == .droppableRealtime else { return nil }
        return replaceableContinuousKind(for: event)
    }

    private func isDroppablePointerMovement(_ event: MirageInput.MirageInputEvent) -> Bool {
        switch event {
        case .mouseMoved,
             .mouseDragged,
             .rightMouseDragged,
             .otherMouseDragged:
            return true
        case let .pointerSampleBatch(batch):
            return batch.isHover
        default:
            return false
        }
    }

    private static func deliveryMode(for event: MirageInput.MirageInputEvent) -> DeliveryMode {
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
        _ event: MirageInput.MirageInputEvent,
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
        _ event: MirageInput.MirageInputEvent,
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) {
        guard event.shouldGateAutomaticProbe else { return }
        interactionLock.lock()
        defer { interactionLock.unlock() }
        lastInteractionTime = now
    }
}
