//
//  PriorityInputClientRouteTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/15/26.
//

#if os(macOS)
@testable import MirageKit
@testable import MirageKitClient
import CoreGraphics
import Foundation
import Network
import Testing

@Suite("Priority Input Client Route")
struct PriorityInputClientRouteTests {
    @Test("Ordered input uses control handler while realtime uses priority route")
    func orderedInputUsesControlHandlerWhileRealtimeUsesPriorityRoute() async throws {
        let endpoint = FakePriorityInputEndpoint()
        let fallbackRecorder = LockedPriorityFallbackRecorder()
        let route = MiragePriorityInputClientRoute(endpoint: endpoint) { data, mode in
            fallbackRecorder.append(data, mode: mode)
        }
        defer { route.stop() }

        let sender = MirageInputEventSender()
        sender.updateSendHandler { data, mode in
            fallbackRecorder.append(data, mode: mode)
        }
        sender.updatePriorityRoute(route)

        sender.sendInputFireAndForget(
            .keyDown(MirageKeyEvent(keyCode: 0x31)),
            streamID: 11
        )
        sender.sendInputFireAndForget(
            .mouseMoved(MirageMouseEvent(location: CGPoint(x: 0.4, y: 0.5), timestamp: 1)),
            streamID: 11
        )

        try await waitUntil("control input send") {
            fallbackRecorder.modes.contains(.orderedBestEffort)
        }
        try await waitUntil("realtime priority send") {
            endpoint.sequencedRealtimePayloadCount > 0
        }
        let sentEnvelope = try MiragePriorityInputEnvelope.deserialize(try #require(endpoint.firstSequencedRealtimePayload))
        endpoint.yield(
            MiragePriorityInputEnvelope(
                kind: .ack,
                eventID: sentEnvelope.eventID,
                streamID: sentEnvelope.streamID,
                deliveryClass: .realtime,
                sentAtUptime: ProcessInfo.processInfo.systemUptime
            )
        )
        try await waitUntil("realtime ack") {
            route.snapshot().realtimeAckCount == 1
        }
        try await Task.sleep(for: .milliseconds(40))

        #expect(endpoint.protectedPayloadCount == 0)
        #expect(endpoint.realtimePayloadCount == 0)
        #expect(endpoint.sequencedRealtimePayloadCount == 1)
        #expect(fallbackRecorder.modes.contains(.orderedBestEffort))
        #expect(!fallbackRecorder.modes.contains(.reliable))
    }

    @Test("Reliable input uses control handler without protected ACK gating")
    func reliableInputUsesControlHandlerWithoutProtectedAckGating() async throws {
        let endpoint = FakePriorityInputEndpoint()
        let fallbackRecorder = PriorityFallbackRecorder()
        let route = MiragePriorityInputClientRoute(endpoint: endpoint) { data, mode in
            await fallbackRecorder.append(data, mode: mode)
        }
        defer { route.stop() }

        let sender = MirageInputEventSender()
        sender.updateSendHandler { data, mode in
            await fallbackRecorder.append(data, mode: mode)
        }
        sender.updatePriorityRoute(route)

        try await sender.sendInput(
            .keyDown(MirageKeyEvent(keyCode: 0x24)),
            streamID: 11
        )

        #expect(endpoint.protectedPayloadCount == 0)
        #expect(await fallbackRecorder.count == 1)
        #expect(await fallbackRecorder.modes == [.reliable])
    }

    @Test("Realtime ack proves priority and suppresses shadow fallback")
    func realtimeAckProvesPriorityAndSuppressesShadowFallback() async throws {
        let endpoint = FakePriorityInputEndpoint()
        let fallbackRecorder = PriorityFallbackRecorder()
        let route = MiragePriorityInputClientRoute(endpoint: endpoint) { data, mode in
            await fallbackRecorder.append(data, mode: mode)
        }
        defer { route.stop() }

        try route.sendRealtime(
            event: .mouseMoved(MirageMouseEvent(location: CGPoint(x: 0.2, y: 0.3), timestamp: 1)),
            streamID: 12
        )
        let sentPayload = try await waitForPayload(endpoint: endpoint)
        let sentEnvelope = try MiragePriorityInputEnvelope.deserialize(sentPayload)
        endpoint.yield(
            MiragePriorityInputEnvelope(
                kind: .ack,
                eventID: sentEnvelope.eventID,
                streamID: sentEnvelope.streamID,
                deliveryClass: .realtime,
                sentAtUptime: ProcessInfo.processInfo.systemUptime
            )
        )

        try await waitUntil("realtime priority ack") {
            route.snapshot().realtimeAckCount == 1
        }
        try await Task.sleep(for: .milliseconds(80))

        #expect(await fallbackRecorder.count == 0)
        #expect(route.snapshot().realtimeFallbackSuppressedCount == 1)
    }

    @Test("Cold realtime input falls back within one frame while priority health is unproven")
    func coldRealtimeInputFallsBackWithinOneFrameWhilePriorityHealthIsUnproven() async throws {
        let endpoint = FakePriorityInputEndpoint()
        let fallbackRecorder = PriorityFallbackRecorder()
        let route = MiragePriorityInputClientRoute(endpoint: endpoint) { data, mode in
            await fallbackRecorder.append(data, mode: mode)
        }
        defer { route.stop() }

        try route.sendRealtime(
            event: .mouseMoved(MirageMouseEvent(location: CGPoint(x: 0.2, y: 0.3), timestamp: 1)),
            streamID: 14
        )

        try await waitUntil("cold realtime fallback", timeout: .milliseconds(80)) {
            await fallbackRecorder.count == 1
        }

        #expect(endpoint.sequencedRealtimePayloadCount == 1)
        #expect(route.snapshot().realtimeFallbackCount == 1)
        #expect(await fallbackRecorder.modes == [.droppableRealtime])
    }

    @Test("Realtime fallback coalesces to latest pending event")
    func realtimeFallbackCoalescesToLatestPendingEvent() async throws {
        let endpoint = FakePriorityInputEndpoint()
        let fallbackRecorder = PriorityFallbackRecorder()
        let route = MiragePriorityInputClientRoute(endpoint: endpoint) { data, mode in
            await fallbackRecorder.append(data, mode: mode)
        }
        defer { route.stop() }

        for index in 0 ..< 3 {
            try route.sendRealtime(
                event: .mouseMoved(MirageMouseEvent(
                    location: CGPoint(x: CGFloat(index), y: 0.3),
                    timestamp: TimeInterval(index)
                )),
                streamID: 15
            )
        }

        try await waitUntil("coalesced realtime fallback", timeout: .milliseconds(80)) {
            await fallbackRecorder.count == 1
        }

        let fallbackEnvelope = try await fallbackRecorder.firstEnvelope()
        let inputMessage = try InputEventMessage.deserializePayload(fallbackEnvelope.inputPayload)
        #expect(endpoint.sequencedRealtimePayloadCount == 3)
        #expect(route.snapshot().realtimeFallbackCount == 1)
        #expect(route.snapshot().realtimeCoalescedCount == 0)
        #expect(inputMessage.event.timestamp == 2)
    }

    @Test("Protected input falls back quickly when priority ack is absent")
    func protectedInputFallsBackQuicklyWhenPriorityAckIsAbsent() async throws {
        let endpoint = FakePriorityInputEndpoint()
        let fallbackRecorder = PriorityFallbackRecorder()
        let route = MiragePriorityInputClientRoute(endpoint: endpoint) { data, mode in
            await fallbackRecorder.append(data, mode: mode)
        }
        defer { route.stop() }

        try await route.send(
            event: .keyDown(MirageKeyEvent(keyCode: 0x24)),
            streamID: 13,
            deliveryMode: .reliable
        )

        #expect(endpoint.protectedPayloadCount == 1)
        #expect(await fallbackRecorder.count == 1)
        #expect(route.snapshot().protectedFallbackCount == 1)
        #expect(route.snapshot().protectedRetryCount == 1)
    }

    @Test("Expected sequenced realtime queue drops do not mark priority unhealthy")
    func expectedSequencedRealtimeQueueDropsDoNotMarkPriorityUnhealthy() async throws {
        let endpoint = FakePriorityInputEndpoint()
        endpoint.sequencedRealtimeCompletionError = NWError.posix(.ECANCELED)
        let fallbackRecorder = PriorityFallbackRecorder()
        let route = MiragePriorityInputClientRoute(endpoint: endpoint) { data, mode in
            await fallbackRecorder.append(data, mode: mode)
        }
        defer { route.stop() }

        try route.sendRealtime(
            event: .mouseMoved(MirageMouseEvent(location: CGPoint(x: 0.2, y: 0.3), timestamp: 1)),
            streamID: 16
        )

        try await waitUntil("sequenced realtime queue drop") {
            route.snapshot().realtimeCoalescedCount == 1
        }

        #expect(route.snapshot().prioritySendErrorCount == 0)
    }

    private func waitForPayload(endpoint: FakePriorityInputEndpoint) async throws -> Data {
        try await waitUntil("priority payload") {
            endpoint.firstSequencedRealtimePayload != nil
        }
        return try #require(endpoint.firstSequencedRealtimePayload)
    }

    private func waitUntil(
        _ label: String,
        timeout: Duration = .seconds(2),
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let start = ContinuousClock.now
        while !(await condition()) {
            if start.duration(to: .now) >= timeout {
                Issue.record("Timed out waiting for \(label)")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private final class FakePriorityInputEndpoint: MiragePriorityInputEndpointProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var realtimePayloads: [Data] = []
    private var sequencedRealtimePayloads: [Data] = []
    private var protectedPayloads: [Data] = []
    private let stream: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private var sequencedRealtimeError: Error?

    init() {
        var continuation: AsyncStream<Data>.Continuation?
        stream = AsyncStream<Data> { createdContinuation in
            continuation = createdContinuation
        }
        guard let continuation else {
            fatalError("AsyncStream did not synchronously create a continuation")
        }
        self.continuation = continuation
    }

    var realtimePayloadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return realtimePayloads.count
    }

    var protectedPayloadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return protectedPayloads.count
    }

    var sequencedRealtimePayloadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sequencedRealtimePayloads.count
    }

    var firstSequencedRealtimePayload: Data? {
        lock.lock()
        defer { lock.unlock() }
        return sequencedRealtimePayloads.first
    }

    var sequencedRealtimeCompletionError: Error? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return sequencedRealtimeError
        }
        set {
            lock.lock()
            sequencedRealtimeError = newValue
            lock.unlock()
        }
    }

    func sendRealtime(
        _ payload: Data,
        onComplete: @escaping @Sendable (Error?) -> Void
    ) {
        lock.lock()
        realtimePayloads.append(payload)
        lock.unlock()
        onComplete(nil)
    }

    func sendRealtimeSequenced(
        _ payload: Data,
        onComplete: @escaping @Sendable (Error?) -> Void
    ) {
        lock.lock()
        sequencedRealtimePayloads.append(payload)
        let error = sequencedRealtimeError
        lock.unlock()
        onComplete(error)
    }

    func sendProtected(
        _ payload: Data,
        onComplete: @escaping @Sendable (Error?) -> Void
    ) {
        lock.lock()
        protectedPayloads.append(payload)
        lock.unlock()
        onComplete(nil)
    }

    func makeIncomingPayloadStream(maxBytes: Int) -> AsyncStream<Data> {
        stream
    }

    func yield(_ envelope: MiragePriorityInputEnvelope) {
        if let payload = try? envelope.serialize() {
            continuation.yield(payload)
        }
    }
}

private actor PriorityFallbackRecorder {
    private(set) var count = 0
    private var recordedModes: [MirageInputEventSender.DeliveryMode] = []
    private var payloads: [Data] = []

    func append(_ data: Data, mode: MirageInputEventSender.DeliveryMode) {
        count += 1
        recordedModes.append(mode)
        payloads.append(data)
    }

    var modes: [MirageInputEventSender.DeliveryMode] {
        recordedModes
    }

    func firstEnvelope() throws -> MiragePriorityInputEnvelope {
        let data = try #require(payloads.first)
        guard case let .success(message, _) = ControlMessage.deserialize(from: data) else {
            throw MirageError.protocolError("Expected serialized priority input control message")
        }
        return try MiragePriorityInputEnvelope.deserialize(message.payload)
    }
}

private final class LockedPriorityFallbackRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedModes: [MirageInputEventSender.DeliveryMode] = []
    private var payloads: [Data] = []

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return payloads.count
    }

    var modes: [MirageInputEventSender.DeliveryMode] {
        lock.lock()
        defer { lock.unlock() }
        return recordedModes
    }

    func append(_ data: Data, mode: MirageInputEventSender.DeliveryMode) {
        lock.lock()
        recordedModes.append(mode)
        payloads.append(data)
        lock.unlock()
    }
}
#endif
