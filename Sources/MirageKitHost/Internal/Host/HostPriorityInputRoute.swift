//
//  HostPriorityInputRoute.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/15/26.
//

import Foundation
import Loom
import MirageKit

#if os(macOS)
struct HostPriorityInputMetricsSnapshot: Equatable, Sendable {
    let priorityReceiveCount: UInt64
    let continuousReceiveCount: UInt64
    let realtimeAckCount: UInt64
    let protectedAckCount: UInt64
    let controlFallbackReceiveCount: UInt64
    let dedupeCount: UInt64
    let malformedEnvelopeCount: UInt64
}

/// Host-side priority input route. Priority packets are decoded directly into
/// the host input scheduler; control-channel envelopes use the same dedupe path
/// as the priority lane.
final class HostPriorityInputRoute: @unchecked Sendable {
    private struct RealtimeInputKey: Hashable {
        let streamID: StreamID
        let kind: RealtimeInputKind
    }

    private enum RealtimeInputKind: Hashable {
        case mouseMoved
        case mouseDragged
        case rightMouseDragged
        case otherMouseDragged
        case scrollWheel
        case stylusHover
    }

    private struct State {
        var endpoint: LoomPriorityInputEndpoint?
        var receiveTask: Task<Void, Never>?
        var seenProtectedEventIDs: Set<UInt64> = []
        var protectedEventIDOrder: [UInt64] = []
        var seenRealtimeEventIDs: Set<UInt64> = []
        var realtimeEventIDOrder: [UInt64] = []
        var latestRealtimeInputTimestampByKey: [RealtimeInputKey: TimeInterval] = [:]
        var lastRealtimeAckAt: CFAbsoluteTime = 0
        var priorityReceiveCount: UInt64 = 0
        var continuousReceiveCount: UInt64 = 0
        var realtimeAckCount: UInt64 = 0
        var protectedAckCount: UInt64 = 0
        var fallbackCount: UInt64 = 0
        var dedupeCount: UInt64 = 0
        var malformedEnvelopeCount: UInt64 = 0
        var closed = false
    }

    private static let maxSeenProtectedEventIDs = 2048
    private static let maxSeenRealtimeEventIDs = 2048
    private static let realtimeAckIntervalSeconds: CFAbsoluteTime = 0.100

    private let sessionID: UUID
    private let clientName: String
    private let controlChannel: MirageControlChannel?
    private let inputScheduler: HostInputMessageScheduler
    private let noteInputActivity: @Sendable (StreamID) -> Void
    private let lock = NSLock()
    private var state = State()

    init(
        sessionID: UUID,
        clientName: String,
        controlChannel: MirageControlChannel,
        inputScheduler: HostInputMessageScheduler,
        noteInputActivity: @escaping @Sendable (StreamID) -> Void = { _ in }
    ) {
        self.sessionID = sessionID
        self.clientName = clientName
        self.controlChannel = controlChannel
        self.inputScheduler = inputScheduler
        self.noteInputActivity = noteInputActivity
    }

    init(
        sessionID: UUID = UUID(),
        clientName: String = "test",
        inputScheduler: HostInputMessageScheduler,
        noteInputActivity: @escaping @Sendable (StreamID) -> Void = { _ in }
    ) {
        self.sessionID = sessionID
        self.clientName = clientName
        controlChannel = nil
        self.inputScheduler = inputScheduler
        self.noteInputActivity = noteInputActivity
    }

    deinit {
        stop()
    }

    func startIfAvailable(clientContext: ClientContext) {
        guard let controlChannel else { return }
        let pathSnapshot = clientContext.pathSnapshot
        let session = controlChannel.session
        Task.detached(priority: .high) { [weak self, session, pathSnapshot] in
            guard let self else { return }
            let transportKind = await session.context?.transportKind
            guard transportKind == .udp || transportKind == .quic else { return }
            guard ClientContext.isPeerToPeerConnection(
                remoteEndpoint: await session.remoteEndpoint,
                pathSnapshot: pathSnapshot
            ) else {
                return
            }

            do {
                let endpoint = try await session.makePriorityInputEndpoint()
                self.install(endpoint: endpoint)
                MirageLogger.host("Priority input lane enabled for \(self.clientName)")
            } catch {
                MirageLogger.host(
                    "Priority input lane unavailable for \(self.clientName); control input fallback remains active: \(error.localizedDescription)"
                )
            }
        }
    }

    func stop() {
        let receiveTask = withState { state -> Task<Void, Never>? in
            guard !state.closed else { return nil }
            state.closed = true
            let task = state.receiveTask
            state.receiveTask = nil
            state.endpoint = nil
            state.seenProtectedEventIDs.removeAll(keepingCapacity: false)
            state.protectedEventIDOrder.removeAll(keepingCapacity: false)
            state.seenRealtimeEventIDs.removeAll(keepingCapacity: false)
            state.realtimeEventIDOrder.removeAll(keepingCapacity: false)
            state.latestRealtimeInputTimestampByKey.removeAll(keepingCapacity: false)
            return task
        }
        receiveTask?.cancel()
    }

    func handleControlInputMessage(_ message: ControlMessage) {
        switch message.type {
        case .inputEvent:
            inputScheduler.enqueue(message)
        case .priorityInputEvent:
            do {
                let envelope = try MiragePriorityInputEnvelope.deserialize(message.payload)
                recordFallback()
                handle(envelope: envelope)
            } catch {
                recordMalformedEnvelope()
                MirageLogger.error(.host, error: error, message: "Failed to decode priority input fallback: ")
            }
        default:
            break
        }
    }

    func snapshot() -> HostPriorityInputMetricsSnapshot {
        withState { state in
            HostPriorityInputMetricsSnapshot(
                priorityReceiveCount: state.priorityReceiveCount,
                continuousReceiveCount: state.continuousReceiveCount,
                realtimeAckCount: state.realtimeAckCount,
                protectedAckCount: state.protectedAckCount,
                controlFallbackReceiveCount: state.fallbackCount,
                dedupeCount: state.dedupeCount,
                malformedEnvelopeCount: state.malformedEnvelopeCount
            )
        }
    }

    private func install(endpoint: LoomPriorityInputEndpoint) {
        let stream = endpoint.makeIncomingPayloadStream()
        let receiveTask = Task.detached(priority: .high) { [weak self] in
            for await payload in stream {
                do {
                    let envelope = try MiragePriorityInputEnvelope.deserialize(payload)
                    self?.handle(envelope: envelope)
                } catch {
                    self?.recordMalformedEnvelope()
                    MirageLogger.error(.host, error: error, message: "Failed to decode priority input payload: ")
                }
            }
        }

        let previousTask = withState { state -> Task<Void, Never>? in
            guard !state.closed else {
                receiveTask.cancel()
                return nil
            }
            let previous = state.receiveTask
            state.endpoint = endpoint
            state.receiveTask = receiveTask
            return previous
        }
        previousTask?.cancel()
    }

    private func handle(envelope: MiragePriorityInputEnvelope) {
        switch envelope.kind {
        case .input:
            handleInputEnvelope(envelope)
        case .continuousInput:
            handleContinuousInputEnvelope(envelope)
        case .ack:
            break
        }
    }

    private func handleInputEnvelope(_ envelope: MiragePriorityInputEnvelope) {
        recordPriorityReceive()
        let accepted = shouldAccept(envelope)
        switch envelope.deliveryClass {
        case .realtime:
            if accepted {
                sendRealtimeAcknowledgementIfNeeded(for: envelope)
            }
        case .protected:
            sendAcknowledgement(for: envelope, kind: .ack)
        }
        guard accepted else { return }

        do {
            let message = try envelope.inputControlMessage()
            if let inputMessage = try? InputEventMessage.deserializePayload(message.payload) {
                noteInputActivity(inputMessage.streamID)
            }
            inputScheduler.enqueue(message)
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to route priority input envelope: ")
        }
    }

    private func handleContinuousInputEnvelope(_ envelope: MiragePriorityInputEnvelope) {
        recordPriorityReceive()
        recordContinuousReceive()
        let accepted = shouldAccept(envelope)
        if accepted {
            sendRealtimeAcknowledgementIfNeeded(for: envelope)
        }
        guard accepted else { return }

        do {
            let batch = try MirageContinuousInputBatch.deserialize(envelope.inputPayload)
            MirageInputLatencyTelemetry.shared.recordHostContinuousBatchReceive(batch)
            noteInputActivity(batch.streamID)
            inputScheduler.enqueueContinuousBatch(batch)
        } catch {
            recordMalformedEnvelope()
            MirageLogger.error(.host, error: error, message: "Failed to route continuous priority input envelope: ")
        }
    }

    private func sendRealtimeAcknowledgementIfNeeded(for envelope: MiragePriorityInputEnvelope) {
        let now = ProcessInfo.processInfo.systemUptime
        let shouldAck = withState { state in
            guard state.lastRealtimeAckAt == 0 ||
                now - state.lastRealtimeAckAt >= Self.realtimeAckIntervalSeconds else {
                return false
            }
            state.lastRealtimeAckAt = now
            return true
        }
        guard shouldAck else { return }
        sendAcknowledgement(for: envelope, kind: .ack)
    }

    private func shouldAccept(_ envelope: MiragePriorityInputEnvelope) -> Bool {
        switch envelope.deliveryClass {
        case .realtime:
            return shouldAcceptRealtime(envelope)
        case .protected:
            return shouldAcceptProtected(envelope)
        }
    }

    private func shouldAcceptProtected(_ envelope: MiragePriorityInputEnvelope) -> Bool {
        return withState { state in
            if state.seenProtectedEventIDs.contains(envelope.eventID) {
                state.dedupeCount &+= 1
                return false
            }
            state.seenProtectedEventIDs.insert(envelope.eventID)
            state.protectedEventIDOrder.append(envelope.eventID)
            while state.protectedEventIDOrder.count > Self.maxSeenProtectedEventIDs {
                let removed = state.protectedEventIDOrder.removeFirst()
                state.seenProtectedEventIDs.remove(removed)
            }
            return true
        }
    }

    private func shouldAcceptRealtime(_ envelope: MiragePriorityInputEnvelope) -> Bool {
        let timestampIdentity = Self.realtimeTimestampIdentity(for: envelope)
        return withState { state in
            if state.seenRealtimeEventIDs.contains(envelope.eventID) {
                state.dedupeCount &+= 1
                return false
            }
            state.seenRealtimeEventIDs.insert(envelope.eventID)
            state.realtimeEventIDOrder.append(envelope.eventID)
            while state.realtimeEventIDOrder.count > Self.maxSeenRealtimeEventIDs {
                let removed = state.realtimeEventIDOrder.removeFirst()
                state.seenRealtimeEventIDs.remove(removed)
            }

            guard let timestampIdentity else { return true }
            let previousTimestamp = state.latestRealtimeInputTimestampByKey[timestampIdentity.key]
            if let previousTimestamp, timestampIdentity.timestamp < previousTimestamp {
                state.dedupeCount &+= 1
                return false
            }
            state.latestRealtimeInputTimestampByKey[timestampIdentity.key] = timestampIdentity.timestamp
            return true
        }
    }

    private static func realtimeTimestampIdentity(
        for envelope: MiragePriorityInputEnvelope
    ) -> (key: RealtimeInputKey, timestamp: TimeInterval)? {
        guard envelope.kind == .input,
              let inputMessage = try? InputEventMessage.deserializePayload(envelope.inputPayload),
              let kind = realtimeInputKind(for: inputMessage.event) else {
            return nil
        }
        return (
            RealtimeInputKey(streamID: inputMessage.streamID, kind: kind),
            inputMessage.event.timestamp
        )
    }

    private static func realtimeInputKind(for event: MirageInputEvent) -> RealtimeInputKind? {
        switch event {
        case .mouseMoved:
            .mouseMoved
        case .mouseDragged:
            .mouseDragged
        case .rightMouseDragged:
            .rightMouseDragged
        case .otherMouseDragged:
            .otherMouseDragged
        case let .scrollWheel(event):
            event.isBoundaryScrollEvent ? nil : .scrollWheel
        case let .pointerSampleBatch(batch):
            batch.phase == .hover ? .stylusHover : nil
        default:
            nil
        }
    }

    private func sendAcknowledgement(
        for envelope: MiragePriorityInputEnvelope,
        kind: MiragePriorityInputEnvelopeKind
    ) {
        let endpoint = withState { state in state.endpoint }
        guard let endpoint else { return }
        let acknowledgement = MiragePriorityInputEnvelope(
            kind: kind,
            eventID: envelope.eventID,
            streamID: envelope.streamID,
            deliveryClass: envelope.deliveryClass,
            sentAtUptime: ProcessInfo.processInfo.systemUptime
        )
        guard let payload = try? acknowledgement.serialize() else { return }
        switch envelope.deliveryClass {
        case .protected:
            withState { state in state.protectedAckCount &+= 1 }
            endpoint.sendProtected(payload)
        case .realtime:
            withState { state in state.realtimeAckCount &+= 1 }
            endpoint.sendRealtime(payload)
        }
    }

    private func recordPriorityReceive() {
        withState { state in
            state.priorityReceiveCount &+= 1
        }
    }

    private func recordContinuousReceive() {
        withState { state in
            state.continuousReceiveCount &+= 1
        }
    }

    private func recordFallback() {
        withState { state in
            state.fallbackCount &+= 1
        }
    }

    private func recordMalformedEnvelope() {
        withState { state in
            state.malformedEnvelopeCount &+= 1
        }
    }

    @discardableResult
    private func withState<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }
}
#endif
