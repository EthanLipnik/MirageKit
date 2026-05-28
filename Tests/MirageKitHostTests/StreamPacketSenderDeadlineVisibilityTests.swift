//
//  StreamPacketSenderDeadlineVisibilityTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/27/26.
//

#if os(macOS)
@testable import MirageKitHost
import Foundation
import MirageKit
import Testing

extension StreamPacketSenderRegressionTests {
    @Test("Local WiFi queued P-frames use infinite sender deadline")
    func localWiFiQueuedPFramesUseInfiniteSenderDeadline() async throws {
        #expect(MirageVideoTransportMode.defaultMode(for: .localWiFi) == .unreliableQueued)
        let submittedPackets = Locked<[StreamPacketSenderSubmittedPacket]>([])
        let dependencyDropCount = Locked(0)
        let blockedFirstKeyframePacket = Locked(false)
        let firstPacketGate = StreamPacketSenderDeadlineSendGate()
        let sender = StreamPacketSender(
            maxPayloadSize: 512,
            sendPacket: { packet, onComplete in
                guard let header = FrameHeader.deserialize(from: packet) else {
                    Issue.record("Failed to deserialize submitted packet")
                    onComplete(nil)
                    return
                }
                submittedPackets.withLock {
                    $0.append(StreamPacketSenderSubmittedPacket(frameNumber: header.frameNumber))
                }
                let shouldBlock = blockedFirstKeyframePacket.withLock { didBlock in
                    guard !didBlock, header.frameNumber == 900 else { return false }
                    didBlock = true
                    return true
                }
                if shouldBlock { firstPacketGate.wait() }
                onComplete(nil)
            },
            videoTransportMode: .unreliableQueued,
            onDependencyFrameDropped: { _, _, _ in dependencyDropCount.withLock { $0 += 1 } }
        )
        defer { firstPacketGate.open() }

        await sender.start()
        let generation = sender.currentGeneration
        sender.enqueue(
            makeStreamPacketWorkItem(
                payload: makeStreamPacketPayload(byteCount: 1024),
                streamID: 45,
                frameNumber: 900,
                sequenceNumberStart: 9000,
                generation: generation,
                isKeyframe: true
            )
        )
        try await waitForStreamPacketSubmissionCount(submittedPackets, expectedCount: 1)

        for frameNumber in 901 ... 903 {
            sender.enqueue(
                makeStreamPacketWorkItem(
                    payload: makeStreamPacketPayload(byteCount: 128),
                    streamID: 45,
                    frameNumber: UInt32(frameNumber),
                    sequenceNumberStart: UInt32(frameNumber * 10),
                    generation: generation
                )
            )
        }

        firstPacketGate.open()
        try await waitForStreamPacketSubmissionCount(submittedPackets, expectedCount: 5)

        let telemetry = await sender.telemetrySnapshot
        #expect(telemetry.senderLocalDeadlineDrops == 0)
        #expect(telemetry.stalePacketDrops == 0)
        #expect(submittedPackets.read { $0.map(\.frameNumber) } == [900, 900, 901, 902, 903])
        #expect(dependencyDropCount.read { $0 == 0 })
        #expect(await !sender.requiresDependencyRecoveryKeyframe())
        #expect(sender.queuedByteCount == 0)

        await sender.stop()
    }

    @Test("Expired queued P-frame opens dependency recovery")
    func expiredQueuedPFrameOpensDependencyRecovery() async throws {
        let submittedPackets = Locked<[StreamPacketSenderSubmittedPacket]>([])
        let dependencyDropCount = Locked(0)
        let blockedFirstPacket = Locked(false)
        let firstPacketGate = StreamPacketSenderDeadlineSendGate()
        let sender = StreamPacketSender(
            maxPayloadSize: 512,
            sendPacket: { packet, onComplete in
                guard let header = FrameHeader.deserialize(from: packet) else {
                    Issue.record("Failed to deserialize submitted packet")
                    onComplete(nil)
                    return
                }
                submittedPackets.withLock {
                    $0.append(StreamPacketSenderSubmittedPacket(frameNumber: header.frameNumber))
                }
                let shouldBlock = blockedFirstPacket.withLock { didBlock in
                    guard !didBlock, header.frameNumber == 700 else { return false }
                    didBlock = true
                    return true
                }
                if shouldBlock { firstPacketGate.wait() }
                onComplete(nil)
            },
            onDependencyFrameDropped: { _, _, _ in dependencyDropCount.withLock { $0 += 1 } }
        )
        defer { firstPacketGate.open() }

        await sender.start()
        let generation = sender.currentGeneration
        sender.enqueue(
            makeStreamPacketWorkItem(
                payload: makeStreamPacketPayload(byteCount: 128),
                streamID: 45,
                frameNumber: 700,
                sequenceNumberStart: 7000,
                generation: generation
            )
        )
        try await waitForStreamPacketSubmissionCount(submittedPackets, expectedCount: 1)

        sender.enqueue(
            makeStreamPacketWorkItem(
                payload: makeStreamPacketPayload(byteCount: 128),
                streamID: 45,
                frameNumber: 701,
                sequenceNumberStart: 7010,
                generation: generation,
                sendDeadline: CFAbsoluteTimeGetCurrent() + 0.020
            )
        )
        try await Task.sleep(for: .milliseconds(60))
        sender.enqueue(
            makeStreamPacketWorkItem(
                payload: makeStreamPacketPayload(byteCount: 128),
                streamID: 45,
                frameNumber: 702,
                sequenceNumberStart: 7020,
                generation: generation
            )
        )

        firstPacketGate.open()
        try await waitForStreamPacketQueuedBytesToDrain(sender)

        let telemetry = await sender.telemetrySnapshot
        #expect(telemetry.stalePacketDrops == 1)
        #expect(telemetry.senderLocalDeadlineDrops == 1)
        #expect(submittedPackets.read { $0.map(\.frameNumber) } == [700])
        #expect(dependencyDropCount.read { $0 == 1 })
        #expect(await sender.requiresDependencyRecoveryKeyframe())

        await sender.stop()
    }

    @Test("P-frame send completes once started")
    func pFrameSendCompletesOnceStarted() async throws {
        let submittedPackets = Locked<[StreamPacketSenderSubmittedPacket]>([])
        let dependencyDropCount = Locked(0)
        let delayedPFrame = Locked(false)
        let sender = StreamPacketSender(
            maxPayloadSize: 512,
            sendPacket: { packet, onComplete in
                guard let header = FrameHeader.deserialize(from: packet) else {
                    Issue.record("Failed to deserialize submitted packet")
                    onComplete(nil)
                    return
                }
                let shouldDelay = submittedPackets.withLock { packets in
                    packets.append(StreamPacketSenderSubmittedPacket(frameNumber: header.frameNumber))
                    return header.frameNumber == 801 && delayedPFrame.withLock { didDelay in
                        guard !didDelay else { return false }
                        didDelay = true
                        return true
                    }
                }
                if shouldDelay {
                    Thread.sleep(forTimeInterval: 0.030)
                }
                onComplete(nil)
            },
            onDependencyFrameDropped: { _, _, _ in dependencyDropCount.withLock { $0 += 1 } }
        )

        await sender.start()
        let generation = sender.currentGeneration
        sender.enqueue(
            makeStreamPacketWorkItem(
                payload: makeStreamPacketPayload(byteCount: 128),
                streamID: 47,
                frameNumber: 800,
                sequenceNumberStart: 8000,
                generation: generation,
                isKeyframe: true
            )
        )
        try await waitForStreamPacketSubmissionCount(submittedPackets, expectedCount: 1)
        try await waitForStreamPacketQueuedBytesToDrain(sender)

        sender.enqueue(
            makeStreamPacketWorkItem(
                payload: makeStreamPacketPayload(byteCount: 1024),
                streamID: 47,
                frameNumber: 801,
                sequenceNumberStart: 8010,
                generation: generation,
                sendDeadline: CFAbsoluteTimeGetCurrent() + 0.015
            )
        )

        try await waitForStreamPacketSubmissionCount(submittedPackets, expectedCount: 2)
        try await Task.sleep(for: .milliseconds(80))

        let telemetry = await sender.telemetrySnapshot
        #expect(telemetry.senderLocalDeadlineDrops == 0)
        #expect(telemetry.stalePacketDrops == 0)
        #expect(submittedPackets.read { $0.map(\.frameNumber) } == [800, 801, 801])
        #expect(dependencyDropCount.read { $0 == 0 })
        #expect(await !sender.requiresDependencyRecoveryKeyframe())

        await sender.stop()
    }

    @Test("Delayed P-frame send does not create partial dependency loss")
    func delayedPFrameSendDoesNotCreatePartialDependencyLoss() async throws {
        let submittedPackets = Locked<[StreamPacketSenderSubmittedPacket]>([])
        let dependencyDropCount = Locked(0)
        let delayedPFrame = Locked(false)
        let sender = StreamPacketSender(
            maxPayloadSize: 512,
            sendPacket: { packet, onComplete in
                guard let header = FrameHeader.deserialize(from: packet) else {
                    Issue.record("Failed to deserialize submitted packet")
                    onComplete(nil)
                    return
                }
                let shouldDelay = submittedPackets.withLock { packets in
                    packets.append(StreamPacketSenderSubmittedPacket(frameNumber: header.frameNumber))
                    return header.frameNumber == 811 && delayedPFrame.withLock { didDelay in
                        guard !didDelay else { return false }
                        didDelay = true
                        return true
                    }
                }
                if shouldDelay {
                    Thread.sleep(forTimeInterval: 0.030)
                }
                onComplete(nil)
            },
            onDependencyFrameDropped: { _, _, reason in
                Issue.record("Unexpected dependency drop: \(reason)")
                dependencyDropCount.withLock { $0 += 1 }
            }
        )

        await sender.start()
        let generation = sender.currentGeneration
        sender.enqueue(
            makeStreamPacketWorkItem(
                payload: makeStreamPacketPayload(byteCount: 128),
                streamID: 47,
                frameNumber: 810,
                sequenceNumberStart: 8100,
                generation: generation,
                isKeyframe: true
            )
        )
        try await waitForStreamPacketSubmissionCount(submittedPackets, expectedCount: 1)
        try await waitForStreamPacketQueuedBytesToDrain(sender)
        try await Task.sleep(for: .milliseconds(250))

        sender.enqueue(
            makeStreamPacketWorkItem(
                payload: makeStreamPacketPayload(byteCount: 1024),
                streamID: 47,
                frameNumber: 811,
                sequenceNumberStart: 8110,
                generation: generation,
                sendDeadline: CFAbsoluteTimeGetCurrent() + 0.015
            )
        )

        try await waitForStreamPacketSubmissionCount(submittedPackets, expectedCount: 2)
        try await Task.sleep(for: .milliseconds(80))

        let telemetry = await sender.telemetrySnapshot
        #expect(telemetry.senderLocalDeadlineDrops == 0)
        #expect(telemetry.stalePacketDrops == 0)
        #expect(submittedPackets.read { $0.map(\.frameNumber) } == [810, 811, 811])
        #expect(dependencyDropCount.read { $0 == 0 })
        #expect(await !sender.requiresDependencyRecoveryKeyframe())

        await sender.stop()
    }
}

private final class StreamPacketSenderDeadlineSendGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var isOpen = false

    func wait() {
        condition.lock()
        while !isOpen {
            condition.wait()
        }
        condition.unlock()
    }

    func open() {
        condition.lock()
        isOpen = true
        condition.broadcast()
        condition.unlock()
    }
}
#endif
