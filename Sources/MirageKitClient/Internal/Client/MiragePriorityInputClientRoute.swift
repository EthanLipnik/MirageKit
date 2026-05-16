//
//  MiragePriorityInputClientRoute.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/15/26.
//

import Foundation
import Loom
import MirageKit
import Network

protocol MiragePriorityInputEndpointProtocol: AnyObject, Sendable {
    func sendRealtime(
        _ payload: Data,
        onComplete: @escaping @Sendable (Error?) -> Void
    )

    func sendRealtimeSequenced(
        _ payload: Data,
        onComplete: @escaping @Sendable (Error?) -> Void
    )

    func sendProtected(
        _ payload: Data,
        onComplete: @escaping @Sendable (Error?) -> Void
    )

    func makeIncomingPayloadStream(maxBytes: Int) -> AsyncStream<Data>
}

extension LoomPriorityInputEndpoint: MiragePriorityInputEndpointProtocol {}

enum MiragePriorityInputClientRouteState: String, Sendable, Equatable {
    case priority
    case fallback
    case recovering
}

struct MiragePriorityInputClientMetricsSnapshot: Equatable, Sendable {
    let routeState: MiragePriorityInputClientRouteState
    let priorityAckAgeMs: Double?
    let realtimeSentCount: UInt64
    let realtimeAckCount: UInt64
    let realtimeFallbackCount: UInt64
    let realtimeFallbackSuppressedCount: UInt64
    let realtimeCoalescedCount: UInt64
    let prioritySendErrorCount: UInt64
    let protectedSentCount: UInt64
    let protectedAckCount: UInt64
    let protectedFallbackCount: UInt64
    let protectedRetryCount: UInt64
    let protectedAckP95Ms: Double
    let protectedAckP99Ms: Double
    let protectedAckMaxMs: Double
    let pendingProtectedCount: Int
    let malformedAckCount: UInt64
}

/// Client-side priority input route with control-channel fallback.
final class MiragePriorityInputClientRoute: @unchecked Sendable {
    private enum RealtimeTransportMode {
        case latest
        case sequenced
    }

    private struct PendingProtectedAck {
        let continuation: CheckedContinuation<Bool, Never>
        let sentAt: CFAbsoluteTime
    }

    private struct PendingRealtimeFallback {
        let envelope: MiragePriorityInputEnvelope
        let deliveryMode: MirageInputEventSender.DeliveryMode
        let reason: RealtimeFallbackReason
    }

    private enum RealtimeFallbackReason {
        case unprovenRoute
        case routeLoss
        case sendError
    }

    private struct State {
        var nextEventID: UInt64 = 1
        var lastPriorityAckAt: CFAbsoluteTime = 0
        var hasProvenRealtimeRoute = false
        var lastRealtimeAckedEventID: UInt64 = 0
        var routeState: MiragePriorityInputClientRouteState = .recovering
        var pendingProtectedAcks: [UInt64: PendingProtectedAck] = [:]
        var completedProtectedAcks: Set<UInt64> = []
        var pendingRealtimeFallback: PendingRealtimeFallback?
        var realtimeFallbackTaskScheduled = false
        var realtimeSentCount: UInt64 = 0
        var realtimeAckCount: UInt64 = 0
        var realtimeCoalescedCount: UInt64 = 0
        var realtimeFallbackCount: UInt64 = 0
        var realtimeFallbackSuppressedCount: UInt64 = 0
        var prioritySendErrorCount: UInt64 = 0
        var protectedSentCount: UInt64 = 0
        var protectedAckCount: UInt64 = 0
        var protectedFallbackCount: UInt64 = 0
        var protectedRetryCount: UInt64 = 0
        var protectedAckLatencySamplesMs: [Double] = []
        var protectedAckMaxMs: Double = 0
        var malformedAckCount: UInt64 = 0
        var lastRouteStateLogAt: CFAbsoluteTime = 0
        var lastLoggedRouteState: MiragePriorityInputClientRouteState?
        var closed = false
    }

    private static let priorityAckFreshnessSeconds: CFAbsoluteTime = 0.500
    private static let realtimeRouteLossSeconds: CFAbsoluteTime = 2.000
    private static let protectedFallbackDelay: Duration = .milliseconds(50)
    private static let realtimeFallbackThrottle: Duration = .milliseconds(16)
    private static let routeStateLogIntervalSeconds: CFAbsoluteTime = 1
    private static let maxProtectedAckLatencySamples = 128

    private let endpoint: MiragePriorityInputEndpointProtocol
    private let fallbackSender: @Sendable (Data, MirageInputEventSender.DeliveryMode) async throws -> Void
    private let lock = NSLock()
    private var state = State()
    private var receiveTask: Task<Void, Never>?

    init(
        endpoint: MiragePriorityInputEndpointProtocol,
        fallbackSender: @escaping @Sendable (Data, MirageInputEventSender.DeliveryMode) async throws -> Void
    ) {
        self.endpoint = endpoint
        self.fallbackSender = fallbackSender
        startReceiving()
    }

    deinit {
        stop()
    }

    func stop() {
        let pendingAcks = withState { state -> [CheckedContinuation<Bool, Never>] in
            guard !state.closed else { return [] }
            state.closed = true
            let continuations = state.pendingProtectedAcks.values.map(\.continuation)
            state.pendingProtectedAcks.removeAll(keepingCapacity: false)
            state.completedProtectedAcks.removeAll(keepingCapacity: false)
            state.pendingRealtimeFallback = nil
            state.realtimeFallbackTaskScheduled = false
            return continuations
        }
        pendingAcks.forEach { $0.resume(returning: false) }
        receiveTask?.cancel()
        receiveTask = nil
    }

    func send(
        event: MirageInputEvent,
        streamID: StreamID,
        deliveryMode: MirageInputEventSender.DeliveryMode
    ) async throws {
        let inputPayload = try InputEventMessage(streamID: streamID, event: event).serializePayload()
        let deliveryClass = deliveryClass(for: deliveryMode)
        let eventID = nextEventID()
        let envelope = MiragePriorityInputEnvelope(
            kind: .input,
            eventID: eventID,
            streamID: streamID,
            deliveryClass: deliveryClass,
            sentAtUptime: ProcessInfo.processInfo.systemUptime,
            inputPayload: inputPayload
        )

        switch deliveryClass {
        case .realtime:
            try sendRealtime(
                envelope: envelope,
                deliveryMode: deliveryMode,
                transportMode: Self.realtimeTransportMode(for: event)
            )
        case .protected:
            try await sendProtected(envelope: envelope, deliveryMode: deliveryMode)
        }
    }

    func sendRealtime(
        event: MirageInputEvent,
        streamID: StreamID
    ) throws {
        let inputPayload = try InputEventMessage(streamID: streamID, event: event).serializePayload()
        let envelope = MiragePriorityInputEnvelope(
            kind: .input,
            eventID: nextEventID(),
            streamID: streamID,
            deliveryClass: .realtime,
            sentAtUptime: ProcessInfo.processInfo.systemUptime,
            inputPayload: inputPayload
        )
        try sendRealtime(
            envelope: envelope,
            deliveryMode: .droppableRealtime,
            transportMode: Self.realtimeTransportMode(for: event)
        )
    }

    func snapshot(
        now: CFAbsoluteTime = ProcessInfo.processInfo.systemUptime
    ) -> MiragePriorityInputClientMetricsSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let ackAgeMs = state.lastPriorityAckAt > 0 ? max(0, now - state.lastPriorityAckAt) * 1000 : nil
        return MiragePriorityInputClientMetricsSnapshot(
            routeState: state.routeState,
            priorityAckAgeMs: ackAgeMs,
            realtimeSentCount: state.realtimeSentCount,
            realtimeAckCount: state.realtimeAckCount,
            realtimeFallbackCount: state.realtimeFallbackCount,
            realtimeFallbackSuppressedCount: state.realtimeFallbackSuppressedCount,
            realtimeCoalescedCount: state.realtimeCoalescedCount,
            prioritySendErrorCount: state.prioritySendErrorCount,
            protectedSentCount: state.protectedSentCount,
            protectedAckCount: state.protectedAckCount,
            protectedFallbackCount: state.protectedFallbackCount,
            protectedRetryCount: state.protectedRetryCount,
            protectedAckP95Ms: Self.percentile(state.protectedAckLatencySamplesMs, percentile: 0.95),
            protectedAckP99Ms: Self.percentile(state.protectedAckLatencySamplesMs, percentile: 0.99),
            protectedAckMaxMs: state.protectedAckMaxMs,
            pendingProtectedCount: state.pendingProtectedAcks.count,
            malformedAckCount: state.malformedAckCount
        )
    }

    private func sendRealtime(
        envelope: MiragePriorityInputEnvelope,
        deliveryMode: MirageInputEventSender.DeliveryMode,
        transportMode: RealtimeTransportMode
    ) throws {
        let payload = try envelope.serialize()
        recordRealtimeSent()
        let completion: @Sendable (Error?) -> Void = { [weak self] error in
            guard let self else { return }
            if let error {
                self.recordRealtimeCoalesced()
                if !Self.isExpectedRealtimeQueueDrop(error) {
                    self.recordPrioritySendError()
                    self.scheduleRealtimeFallback(
                        envelope: envelope,
                        deliveryMode: deliveryMode,
                        reason: .sendError
                    )
                }
            }
        }
        switch transportMode {
        case .latest:
            endpoint.sendRealtime(payload, onComplete: completion)
        case .sequenced:
            endpoint.sendRealtimeSequenced(payload, onComplete: completion)
        }

        if let fallbackReason = realtimeFallbackReason() {
            scheduleRealtimeFallback(
                envelope: envelope,
                deliveryMode: deliveryMode,
                reason: fallbackReason
            )
        }
    }

    private func sendProtected(
        envelope: MiragePriorityInputEnvelope,
        deliveryMode: MirageInputEventSender.DeliveryMode
    ) async throws {
        let payload = try envelope.serialize()
        recordProtectedSent()
        endpoint.sendProtected(payload) { [weak self] error in
            if error != nil {
                self?.recordPrioritySendError()
            }
        }
        let acked = await waitForProtectedAck(
            eventID: envelope.eventID,
            sentAt: envelope.sentAtUptime
        )
        if acked { return }
        recordProtectedRetry()
        do {
            try await sendFallback(envelope: envelope, deliveryMode: deliveryMode)
        } catch {
            markRouteState(.fallback)
            throw error
        }
    }

    private func startReceiving() {
        receiveTask = Task.detached(priority: .high) { [weak self, endpoint] in
            for await payload in endpoint.makeIncomingPayloadStream(maxBytes: LoomPriorityInputEndpoint.maximumPayloadBytes) {
                self?.handlePriorityPayload(payload)
            }
        }
    }

    private func handlePriorityPayload(_ payload: Data) {
        guard let envelope = try? MiragePriorityInputEnvelope.deserialize(payload) else {
            recordMalformedAck()
            return
        }
        switch envelope.kind {
        case .ack:
            switch envelope.deliveryClass {
            case .realtime:
                notePriorityAck(envelope)
                recordRealtimeAck()
            case .protected:
                notePriorityAck(envelope)
                completeProtectedAck(eventID: envelope.eventID, acked: true)
            }
        case .input:
            break
        }
    }

    private func waitForProtectedAck(
        eventID: UInt64,
        sentAt: CFAbsoluteTime
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { [weak self] in
                guard let self else { return false }
                return await self.registerProtectedAckWaiter(eventID: eventID, sentAt: sentAt)
            }
            group.addTask {
                try? await Task.sleep(for: Self.protectedFallbackDelay)
                return false
            }

            let result = await group.next() ?? false
            group.cancelAll()
            if !result {
                completeProtectedAck(eventID: eventID, acked: false)
                markRouteState(.fallback)
            }
            return result
        }
    }

    private func registerProtectedAckWaiter(
        eventID: UInt64,
        sentAt: CFAbsoluteTime
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            var shouldResume = false
            var resumeValue = false
            withState { state in
                if state.closed {
                    shouldResume = true
                } else if state.completedProtectedAcks.remove(eventID) != nil {
                    shouldResume = true
                    resumeValue = true
                } else {
                    state.pendingProtectedAcks[eventID] = PendingProtectedAck(
                        continuation: continuation,
                        sentAt: sentAt
                    )
                }
            }
            if shouldResume {
                continuation.resume(returning: resumeValue)
            }
        }
    }

    private func completeProtectedAck(eventID: UInt64, acked: Bool) {
        let continuation = withState { state in
            let pending = state.pendingProtectedAcks.removeValue(forKey: eventID)
            if let pending, acked {
                let latencyMs = max(0, ProcessInfo.processInfo.systemUptime - pending.sentAt) * 1000
                state.protectedAckCount &+= 1
                state.protectedAckMaxMs = max(state.protectedAckMaxMs, latencyMs)
                state.protectedAckLatencySamplesMs.append(latencyMs)
                if state.protectedAckLatencySamplesMs.count > Self.maxProtectedAckLatencySamples {
                    state.protectedAckLatencySamplesMs.removeFirst(
                        state.protectedAckLatencySamplesMs.count - Self.maxProtectedAckLatencySamples
                    )
                }
            }
            if pending == nil, acked, !state.closed {
                state.completedProtectedAcks.insert(eventID)
                if state.completedProtectedAcks.count > 128,
                   let oldest = state.completedProtectedAcks.min() {
                    state.completedProtectedAcks.remove(oldest)
                }
            }
            return pending?.continuation
        }
        continuation?.resume(returning: acked)
    }

    private func scheduleRealtimeFallback(
        envelope: MiragePriorityInputEnvelope,
        deliveryMode: MirageInputEventSender.DeliveryMode,
        reason: RealtimeFallbackReason
    ) {
        let shouldStartTask = withState { state in
            guard !state.closed else { return false }
            state.pendingRealtimeFallback = PendingRealtimeFallback(
                envelope: envelope,
                deliveryMode: deliveryMode,
                reason: reason
            )
            guard !state.realtimeFallbackTaskScheduled else { return false }
            state.realtimeFallbackTaskScheduled = true
            return true
        }
        guard shouldStartTask else { return }
        Task.detached(priority: .high) { [weak self] in
            try? await Task.sleep(for: Self.realtimeFallbackThrottle)
            await self?.drainRealtimeFallback()
        }
    }

    private func drainRealtimeFallback() async {
        let pending = withState { state -> PendingRealtimeFallback? in
            state.realtimeFallbackTaskScheduled = false
            guard !state.closed else { return nil }
            guard let pending = state.pendingRealtimeFallback else { return nil }
            state.pendingRealtimeFallback = nil
            guard !Self.shouldSuppressRealtimeFallbackLocked(state: state, pending: pending) else {
                state.realtimeFallbackSuppressedCount &+= 1
                return nil
            }
            return pending
        }
        guard let pending else { return }
        do {
            try await sendFallback(
                envelope: pending.envelope,
                deliveryMode: pending.deliveryMode
            )
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed realtime input fallback: ")
        }
    }

    private func sendFallback(
        envelope: MiragePriorityInputEnvelope,
        deliveryMode: MirageInputEventSender.DeliveryMode
    ) async throws {
        recordFallback(for: envelope.deliveryClass)
        MirageInputLatencyTelemetry.shared.recordClientFallback(envelope: envelope)
        let controlMessage = try ControlMessage(type: .priorityInputEvent, payload: envelope.serialize())
        try await fallbackSender(controlMessage.serialize(), deliveryMode)
    }

    private func realtimeFallbackReason(
        now: CFAbsoluteTime = ProcessInfo.processInfo.systemUptime
    ) -> RealtimeFallbackReason? {
        lock.lock()
        defer { lock.unlock() }
        guard !state.closed else { return nil }
        if !state.hasProvenRealtimeRoute {
            return .unprovenRoute
        }
        guard state.lastPriorityAckAt > 0 else {
            return .routeLoss
        }
        return now - state.lastPriorityAckAt > Self.realtimeRouteLossSeconds ? .routeLoss : nil
    }

    private static func isPriorityHealthyLocked(
        state: State,
        now: CFAbsoluteTime = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        state.lastPriorityAckAt > 0 && now - state.lastPriorityAckAt <= priorityAckFreshnessSeconds
    }

    private static func shouldSuppressRealtimeFallbackLocked(
        state: State,
        pending: PendingRealtimeFallback,
        now: CFAbsoluteTime = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        switch pending.reason {
        case .sendError:
            return false
        case .unprovenRoute:
            return state.hasProvenRealtimeRoute && isPriorityHealthyLocked(state: state, now: now)
        case .routeLoss:
            guard state.lastRealtimeAckedEventID >= pending.envelope.eventID else {
                return false
            }
            return isPriorityHealthyLocked(state: state, now: now)
        }
    }

    private static func isExpectedRealtimeQueueDrop(_ error: Error) -> Bool {
        if let networkError = error as? NWError,
           case .posix(.ECANCELED) = networkError {
            return true
        }

        let nsError = error as NSError
        return nsError.domain == NSPOSIXErrorDomain && nsError.code == 89
    }

    private func notePriorityAck(_ envelope: MiragePriorityInputEnvelope) {
        let shouldLog = withState { state in
            state.lastPriorityAckAt = ProcessInfo.processInfo.systemUptime
            if envelope.deliveryClass == .realtime {
                state.hasProvenRealtimeRoute = true
                state.lastRealtimeAckedEventID = max(state.lastRealtimeAckedEventID, envelope.eventID)
            }
            state.routeState = .priority
            return shouldLogRouteStateLocked(&state, routeState: .priority)
        }
        if shouldLog {
            MirageLogger.client("Priority input route recovered on input ack")
        }
    }

    private func markRouteState(_ routeState: MiragePriorityInputClientRouteState) {
        let shouldLog = withState { state in
            state.routeState = routeState
            return shouldLogRouteStateLocked(&state, routeState: routeState)
        }
        if shouldLog {
            MirageLogger.client("Priority input route state=\(routeState.rawValue)")
        }
    }

    private func shouldLogRouteStateLocked(
        _ state: inout State,
        routeState: MiragePriorityInputClientRouteState,
        now: CFAbsoluteTime = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        guard state.lastLoggedRouteState != routeState else { return false }
        guard state.lastRouteStateLogAt == 0 ||
            now - state.lastRouteStateLogAt >= Self.routeStateLogIntervalSeconds else {
            return false
        }
        state.lastLoggedRouteState = routeState
        state.lastRouteStateLogAt = now
        return true
    }

    private func recordRealtimeSent() {
        withState { state in
            state.realtimeSentCount &+= 1
        }
    }

    private func recordRealtimeAck() {
        withState { state in
            state.realtimeAckCount &+= 1
        }
    }

    private func recordRealtimeCoalesced() {
        withState { state in
            state.realtimeCoalescedCount &+= 1
        }
    }

    private func recordFallback(for deliveryClass: MiragePriorityInputDeliveryClass) {
        withState { state in
            switch deliveryClass {
            case .realtime:
                state.realtimeFallbackCount &+= 1
            case .protected:
                state.protectedFallbackCount &+= 1
            }
            state.routeState = .fallback
        }
    }

    private func recordPrioritySendError() {
        withState { state in
            state.prioritySendErrorCount &+= 1
            state.routeState = .fallback
        }
    }

    private func recordProtectedSent() {
        withState { state in
            state.protectedSentCount &+= 1
        }
    }

    private func recordProtectedRetry() {
        withState { state in
            state.protectedRetryCount &+= 1
        }
    }

    private func recordMalformedAck() {
        withState { state in
            state.malformedAckCount &+= 1
        }
    }

    private func nextEventID() -> UInt64 {
        withState { state in
            let eventID = state.nextEventID
            state.nextEventID &+= 1
            if state.nextEventID == 0 {
                state.nextEventID = 1
            }
            return eventID
        }
    }

    private func deliveryClass(
        for deliveryMode: MirageInputEventSender.DeliveryMode
    ) -> MiragePriorityInputDeliveryClass {
        switch deliveryMode {
        case .droppableRealtime:
            .realtime
        case .reliable, .orderedBestEffort:
            .protected
        }
    }

    private static func realtimeTransportMode(for event: MirageInputEvent) -> RealtimeTransportMode {
        switch event {
        case .mouseMoved,
             .mouseDragged,
             .rightMouseDragged,
             .otherMouseDragged:
            .latest
        case let .pointerSampleBatch(batch) where batch.phase == .hover:
            .latest
        default:
            .latest
        }
    }

    @discardableResult
    private func withState<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }

    private static func percentile(_ values: [Double], percentile: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let clamped = max(0, min(1, percentile))
        let index = Int((Double(sorted.count - 1) * clamped).rounded(.up))
        return sorted[min(sorted.count - 1, max(0, index))]
    }
}
