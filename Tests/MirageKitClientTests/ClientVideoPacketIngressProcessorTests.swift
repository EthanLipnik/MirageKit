//
//  ClientVideoPacketIngressProcessorTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/10/26.
//

@testable import MirageKitClient
import Foundation
import MirageKit
import Testing

@Suite("Client Video Packet Ingress Processor")
struct ClientVideoPacketIngressProcessorTests {
    @Test("Processor drains enqueued batches in order")
    func processorDrainsEnqueuedBatchesInOrder() async throws {
        let collector = PacketProcessingGate()
        let processor = ClientVideoPacketIngressProcessor(streamID: 42) { data, streamID in
            collector.record(data, streamID: streamID)
        }
        defer { processor.finish() }

        let expected = (0 ..< 5).map { Data([$0]) }
        processor.enqueue(Array(expected[0 ..< 2]))
        processor.enqueue(Array(expected[2 ..< 5]))

        let received = try #require(
            await collector.payloads(target: expected.count, timeoutSeconds: 1.0)
        )
        #expect(received.map(\.data) == expected)
        #expect(received.map(\.streamID) == Array(repeating: 42, count: expected.count))

        let snapshot = processor.snapshot()
        #expect(snapshot.processedPacketCount == UInt64(expected.count))
        #expect(snapshot.loomStreamDeliveryFPS >= Double(expected.count))
        #expect(snapshot.loomStreamDeliveryIntervalMaxMs < 100)
        #expect(snapshot.rawPacketIngressFPS >= Double(expected.count))
        #expect(snapshot.incomingBatchFPS >= 2)
        #expect(snapshot.incomingBatchMaxSize == 3)
        #expect(snapshot.processorWakeDelayMaxMs < 100)
    }

    @Test("Processor trims overload without age-based packet drops")
    func processorTrimsOverloadWithoutAgeBasedPacketDrops() async throws {
        let gate = PacketProcessingGate()
        let processor = ClientVideoPacketIngressProcessor(
            streamID: 7,
            maxQueuedBatches: 2,
            maxQueuedPackets: 2
        ) { data, streamID in
            gate.record(data, streamID: streamID)
        }
        defer {
            gate.unblock()
            processor.finish()
        }

        gate.block()
        processor.enqueue([Data([0])])
        try await Task.sleep(for: .milliseconds(5))
        var snapshot = processor.snapshot()
        #expect(snapshot.stalePacketDropCount == 0)

        processor.enqueue([Data([2])])
        processor.enqueue([Data([3])])
        processor.enqueue([Data([4])])
        processor.enqueue([Data([5])])

        snapshot = processor.snapshot()
        #expect(snapshot.stalePacketDropCount > 0)
        #expect(snapshot.queuedPacketCount <= 2)

        gate.unblock()
        _ = await gate.payloads(timeoutSeconds: 1.0)
        snapshot = processor.snapshot()
        #expect(snapshot.queueAgeMaxMs >= 0)
    }
}

private struct ReceivedPacket: Sendable, Equatable {
    let data: Data
    let streamID: StreamID
}

private final class PacketProcessingGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isBlocked = false
    private var received: [ReceivedPacket] = []

    func block() {
        lock.lock()
        isBlocked = true
        lock.unlock()
    }

    func unblock() {
        lock.lock()
        isBlocked = false
        lock.unlock()
    }

    func record(_ data: Data, streamID: StreamID) {
        while true {
            lock.lock()
            let blocked = isBlocked
            lock.unlock()
            if !blocked { break }
            Thread.sleep(forTimeInterval: 0.005)
        }

        lock.lock()
        received.append(ReceivedPacket(data: data, streamID: streamID))
        lock.unlock()
    }

    func payloads(target: Int, timeoutSeconds: TimeInterval) async -> [ReceivedPacket]? {
        let deadline = CFAbsoluteTimeGetCurrent() + timeoutSeconds
        while CFAbsoluteTimeGetCurrent() < deadline {
            let snapshot = snapshot()
            if snapshot.count >= target { return Array(snapshot.prefix(target)) }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    func payloads(timeoutSeconds: TimeInterval) async -> [ReceivedPacket] {
        let deadline = CFAbsoluteTimeGetCurrent() + timeoutSeconds
        while CFAbsoluteTimeGetCurrent() < deadline {
            let snapshot = snapshot()
            if !snapshot.isEmpty { return snapshot }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return snapshot()
    }

    private func snapshot() -> [ReceivedPacket] {
        lock.lock()
        let snapshot = received
        lock.unlock()
        return snapshot
    }
}
