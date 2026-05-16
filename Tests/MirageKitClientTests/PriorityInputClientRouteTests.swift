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
import Testing

@Suite("Priority Input Client Route")
struct PriorityInputClientRouteTests {
    @Test("Realtime priority input is not blocked by protected fallback timeout")
    func realtimePriorityInputIsNotBlockedByProtectedFallbackTimeout() async throws {
        let endpoint = FakePriorityInputEndpoint()
        let fallbackRecorder = PriorityFallbackRecorder()
        let route = MiragePriorityInputClientRoute(endpoint: endpoint) { data, mode in
            await fallbackRecorder.append(data, mode: mode)
        }
        defer { route.stop() }

        let sender = MirageInputEventSender()
        sender.updatePriorityRoute(route)

        sender.sendInputFireAndForget(
            .keyDown(MirageKeyEvent(keyCode: 0x31)),
            streamID: 11
        )
        sender.sendInputFireAndForget(
            .mouseMoved(MirageMouseEvent(location: CGPoint(x: 0.4, y: 0.5), timestamp: 1)),
            streamID: 11
        )

        try await waitUntil("realtime priority send") {
            endpoint.realtimePayloadCount > 0
        }

        #expect(endpoint.protectedPayloadCount == 1)
        #expect(endpoint.realtimePayloadCount == 1)
        #expect(await fallbackRecorder.count == 0)
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

    private func waitForPayload(endpoint: FakePriorityInputEndpoint) async throws -> Data {
        try await waitUntil("priority payload") {
            endpoint.firstRealtimePayload != nil
        }
        return try #require(endpoint.firstRealtimePayload)
    }

    private func waitUntil(
        _ label: String,
        timeout: Duration = .milliseconds(500),
        condition: @escaping @Sendable () -> Bool
    ) async throws {
        let start = ContinuousClock.now
        while !condition() {
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
    private var protectedPayloads: [Data] = []
    private let stream: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation

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

    var firstRealtimePayload: Data? {
        lock.lock()
        defer { lock.unlock() }
        return realtimePayloads.first
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
    private var modes: [MirageInputEventSender.DeliveryMode] = []

    func append(_ data: Data, mode: MirageInputEventSender.DeliveryMode) {
        _ = data
        count += 1
        modes.append(mode)
    }
}
#endif
