//
//  ClientVideoPacketIngressProcessorTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/10/26.
//

@testable import MirageKitClient
import Foundation
import Loom
@testable import MirageKit
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
        #expect(snapshot.loomStreamDeliveryPPS >= Double(expected.count))
        #expect(snapshot.loomStreamDeliveryIntervalMaxMs < 100)
        #expect(snapshot.rawPacketIngressPPS >= Double(expected.count))
        #expect(snapshot.incomingBatchRate >= 2)
        #expect(snapshot.incomingBatchMaxSize == 3)
        #expect(snapshot.stalePacketDropCount == 0)
        #expect(snapshot.overloadPacketDropCount == 0)
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
        #expect(snapshot.stalePacketDropCount == 0)
        #expect(snapshot.overloadPacketDropCount > 0)
        #expect(snapshot.queuedPacketCount <= 2)

        gate.unblock()
        _ = await gate.payloads(timeoutSeconds: 1.0)
        snapshot = processor.snapshot()
        #expect(snapshot.queueAgeMaxMs >= 0)
    }

    @Test("Processor trims stale non-recovery packets")
    func processorTrimsStaleNonRecoveryPackets() async throws {
        let gate = PacketProcessingGate()
        let processor = ClientVideoPacketIngressProcessor(
            streamID: 7,
            maxQueuedBatches: 8,
            maxQueuedPackets: 64,
            staleNonRecoveryPacketAge: 0.025
        ) { data, streamID in
            gate.record(data, streamID: streamID)
        }
        defer {
            gate.unblock()
            processor.finish()
        }

        let blocker = Data([0])
        let stalePFrame = makeVideoPacket(streamID: 7, frameNumber: 1, flags: [])
        let keyframe = makeVideoPacket(streamID: 7, frameNumber: 2, flags: [.keyframe])

        gate.block()
        processor.enqueue([blocker])
        try #require(await gate.startedPayloads(containing: blocker, timeoutSeconds: 1.0).contains {
            $0.data == blocker
        })
        processor.enqueue([stalePFrame])
        try await Task.sleep(for: .milliseconds(50))
        processor.enqueue([keyframe])

        let snapshot = processor.snapshot()
        #expect(snapshot.stalePacketDropCount == 1)
        #expect(snapshot.overloadPacketDropCount == 0)

        gate.unblock()
        let received = await gate.payloads(containing: keyframe, timeoutSeconds: 1.0)
        #expect(received.map(\.data).contains(keyframe))
        #expect(!received.map(\.data).contains(stalePFrame))
    }

    @Test("Processor preserves stale recovery packets while trimming stale P-frames")
    func processorPreservesStaleRecoveryPacketsWhileTrimmingStalePFrames() async throws {
        let gate = PacketProcessingGate()
        let processor = ClientVideoPacketIngressProcessor(
            streamID: 7,
            maxQueuedBatches: 8,
            maxQueuedPackets: 64,
            staleNonRecoveryPacketAge: 0.025
        ) { data, streamID in
            gate.record(data, streamID: streamID)
        }
        defer {
            gate.unblock()
            processor.finish()
        }

        let blocker = Data([0])
        let stalePFrame = makeVideoPacket(streamID: 7, frameNumber: 10, flags: [])
        let keyframe = makeVideoPacket(streamID: 7, frameNumber: 11, flags: [.keyframe])
        let parameterSet = makeVideoPacket(streamID: 7, frameNumber: 12, flags: [.parameterSet])
        let discontinuity = makeVideoPacket(streamID: 7, frameNumber: 13, flags: [.discontinuity])
        let priority = makeVideoPacket(streamID: 7, frameNumber: 14, flags: [.priority])
        let recoveryPackets = [keyframe, parameterSet, discontinuity, priority]

        gate.block()
        processor.enqueue([blocker])
        try #require(await gate.startedPayloads(containing: blocker, timeoutSeconds: 1.0).contains {
            $0.data == blocker
        })
        processor.enqueue([stalePFrame] + recoveryPackets)
        try await Task.sleep(for: .milliseconds(50))

        let snapshot = processor.snapshot()
        #expect(snapshot.stalePacketDropCount == 1)
        #expect(snapshot.queuedPacketCount == recoveryPackets.count)

        gate.unblock()
        let received = await gate.payloads(target: recoveryPackets.count + 1, timeoutSeconds: 1.0) ?? []
        let receivedPayloads = received.map(\.data)
        #expect(!receivedPayloads.contains(stalePFrame))
        for packet in recoveryPackets {
            #expect(receivedPayloads.contains(packet))
        }
    }

    @Test("Processor only hard-drops under explicit overload")
    func processorOnlyHardDropsUnderExplicitOverload() async throws {
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

        let blocker = Data([0])
        let pFrame = makeVideoPacket(streamID: 7, frameNumber: 1, flags: [])
        let keyframe = makeVideoPacket(streamID: 7, frameNumber: 2, flags: [.keyframe])
        let laterPFrame = makeVideoPacket(streamID: 7, frameNumber: 3, flags: [])

        gate.block()
        processor.enqueue([blocker])
        processor.enqueue([pFrame])
        processor.enqueue([keyframe])
        processor.enqueue([laterPFrame])

        let snapshot = processor.snapshot()
        #expect(snapshot.stalePacketDropCount == 0)
        #expect(snapshot.overloadPacketDropCount > 0)

        gate.unblock()
        let received = await gate.payloads(containing: keyframe, timeoutSeconds: 1.0)
        #expect(received.map(\.data).contains(keyframe))
    }

    @MainActor
    @Test("Video stream listener installs one-packet immediate ingress handler")
    func videoStreamListenerInstallsOnePacketImmediateIngressHandler() async throws {
        let pair = try await makeLoopbackControlPair()
        try await pair.startAuthenticatedSessions()
        let service = MirageClientService(deviceName: "Client Ingress Test")
        service.loomSession = pair.client
        service.startMediaStreamListener()

        let videoStream = try await pair.server.openStream(label: "video/77")
        do {
            let processor = try #require(await waitForProcessor(service: service, streamID: 77))
            for index in 0 ..< 3 {
                try await videoStream.sendUnreliable(Data([UInt8(index)]))
            }

            try #require(await waitForProcessedPackets(processor: processor, count: 3))
            let snapshot = processor.snapshot()
            #expect(snapshot.incomingBatchMaxSize == 1)
            #expect(snapshot.processedPacketCount >= 3)

            service.stopMediaStreamListener()
            #expect(service.videoPacketIngressProcessors[77] == nil)
            #expect(service.activeMediaStreams["video/77"] == nil)
            try? await videoStream.close()
            await pair.stop()
        } catch {
            service.stopMediaStreamListener()
            try? await videoStream.close()
            await pair.stop()
            throw error
        }
    }
}

@MainActor
private func waitForProcessor(
    service: MirageClientService,
    streamID: StreamID
) async -> ClientVideoPacketIngressProcessor? {
    let deadline = CFAbsoluteTimeGetCurrent() + 1.0
    while CFAbsoluteTimeGetCurrent() < deadline {
        if let processor = service.videoPacketIngressProcessors[streamID] {
            return processor
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return nil
}

private func waitForProcessedPackets(
    processor: ClientVideoPacketIngressProcessor,
    count: UInt64
) async -> Bool {
    let deadline = CFAbsoluteTimeGetCurrent() + 1.0
    while CFAbsoluteTimeGetCurrent() < deadline {
        if processor.snapshot().processedPacketCount >= count {
            return true
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}

private func makeVideoPacket(
    streamID: StreamID,
    frameNumber: UInt32,
    flags: FrameFlags
) -> Data {
    FrameHeader(
        flags: flags,
        streamID: streamID,
        sequenceNumber: frameNumber,
        timestamp: UInt64(frameNumber),
        frameNumber: frameNumber,
        fragmentIndex: 0,
        fragmentCount: 1,
        payloadLength: 0,
        frameByteCount: 0,
        checksum: 0
    ).serialize()
}

private struct ReceivedPacket: Sendable, Equatable {
    let data: Data
    let streamID: StreamID
}

private final class PacketProcessingGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isBlocked = false
    private var started: [ReceivedPacket] = []
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
        lock.lock()
        started.append(ReceivedPacket(data: data, streamID: streamID))
        lock.unlock()

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

    func payloads(containing data: Data, timeoutSeconds: TimeInterval) async -> [ReceivedPacket] {
        let deadline = CFAbsoluteTimeGetCurrent() + timeoutSeconds
        while CFAbsoluteTimeGetCurrent() < deadline {
            let snapshot = snapshot()
            if snapshot.contains(where: { $0.data == data }) { return snapshot }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return snapshot()
    }

    func startedPayloads(containing data: Data, timeoutSeconds: TimeInterval) async -> [ReceivedPacket] {
        let deadline = CFAbsoluteTimeGetCurrent() + timeoutSeconds
        while CFAbsoluteTimeGetCurrent() < deadline {
            let snapshot = startedSnapshot()
            if snapshot.contains(where: { $0.data == data }) { return snapshot }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return startedSnapshot()
    }

    private func snapshot() -> [ReceivedPacket] {
        lock.lock()
        let snapshot = received
        lock.unlock()
        return snapshot
    }

    private func startedSnapshot() -> [ReceivedPacket] {
        lock.lock()
        let snapshot = started
        lock.unlock()
        return snapshot
    }
}
