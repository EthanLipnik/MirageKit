//
//  StreamPacketSenderDeadlineRegressionTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

#if os(macOS)
@testable import MirageKitHost
import Foundation
import MirageKit
import Testing

extension StreamPacketSenderRegressionTests {
    @Test("Expired non-keyframes before enqueue open dependency recovery")
    func expiredNonKeyframesBeforeEnqueueOpenDependencyRecovery() async throws {
        let submittedPackets = Locked<[StreamPacketSenderSubmittedPacket]>([])
        let dependencyDropCount = Locked(0)
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
                onComplete(nil)
            },
            onDependencyFrameDropped: { _, _, _ in dependencyDropCount.withLock { $0 += 1 } }
        )

        await sender.start()
        let generation = sender.currentGeneration
        sender.enqueue(
            makeStreamPacketWorkItem(
                payload: makeStreamPacketPayload(byteCount: 128),
                streamID: 45,
                frameNumber: 302,
                sequenceNumberStart: 3010,
                generation: generation,
                sendDeadline: CFAbsoluteTimeGetCurrent() - 0.001
            )
        )

        try await Task.sleep(for: .milliseconds(50))

        let telemetry = await sender.telemetrySnapshot
        #expect(telemetry.stalePacketDrops == 1)
        #expect(telemetry.senderLocalDeadlineDrops == 1)
        #expect(submittedPackets.read { $0.isEmpty })
        #expect(dependencyDropCount.read { $0 == 1 })
        #expect(await sender.requiresDependencyRecoveryKeyframe())
        #expect(sender.queuedByteCount == 0)

        await sender.stop()
    }

    @Test("Default non-keyframe delivery preserves dependency frames")
    func defaultNonKeyframeDeliveryPreservesDependencyFrame() async throws {
        let submittedPackets = Locked<[StreamPacketSenderSubmittedPacket]>([])
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
                onComplete(nil)
            }
        )

        await sender.start()
        let generation = sender.currentGeneration
        sender.enqueue(
            makeStreamPacketWorkItem(
                payload: makeStreamPacketPayload(byteCount: 128),
                streamID: 45,
                frameNumber: 303,
                sequenceNumberStart: 3020,
                generation: generation,
                encodedAt: CFAbsoluteTimeGetCurrent() - 10
            )
        )

        try await waitForStreamPacketSubmissionCount(submittedPackets, expectedCount: 1)

        let telemetry = await sender.telemetrySnapshot
        #expect(telemetry.stalePacketDrops == 0)
        #expect(submittedPackets.read { $0.map(\.frameNumber) } == [303])
        #expect(sender.queuedByteCount == 0)

        await sender.stop()
    }

    @Test("Finite non-keyframe deadline does not prevent delivery")
    func finiteNonKeyframeDeadlineDoesNotPreventDelivery() async throws {
        let submittedPackets = Locked<[StreamPacketSenderSubmittedPacket]>([])
        let dependencyDropCount = Locked(0)
        let sender = StreamPacketSender(
            maxPayloadSize: 1200,
            sendPacket: { packet, onComplete in
                guard let header = FrameHeader.deserialize(from: packet) else {
                    Issue.record("Failed to deserialize submitted packet")
                    onComplete(nil)
                    return
                }
                submittedPackets.withLock {
                    $0.append(StreamPacketSenderSubmittedPacket(frameNumber: header.frameNumber))
                }
                onComplete(nil)
            },
            onDependencyFrameDropped: { _, _, _ in dependencyDropCount.withLock { $0 += 1 } }
        )

        await sender.start()
        let generation = sender.currentGeneration
        sender.enqueue(
            makeStreamPacketWorkItem(
                payload: makeStreamPacketPayload(byteCount: 1200),
                streamID: 45,
                frameNumber: 304,
                sequenceNumberStart: 3030,
                generation: generation,
                sendDeadline: CFAbsoluteTimeGetCurrent() + 0.020
            )
        )

        try await waitForStreamPacketSubmissionCount(submittedPackets, expectedCount: 1)
        try await waitForStreamPacketQueuedBytesToDrain(sender)

        let telemetry = await sender.telemetrySnapshot
        #expect(telemetry.stalePacketDrops == 0)
        #expect(telemetry.senderLocalDeadlineDrops == 0)
        #expect(submittedPackets.read { $0.map(\.frameNumber) } == [304])
        #expect(dependencyDropCount.read { $0 == 0 })
        #expect(await !sender.requiresDependencyRecoveryKeyframe())
        #expect(sender.queuedByteCount == 0)

        await sender.stop()
    }

    @Test("Queued non-keyframes send in dependency order")
    func queuedNonKeyframesSendInDependencyOrder() async throws {
        let submittedPackets = Locked<[StreamPacketSenderSubmittedPacket]>([])
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
                onComplete(nil)
            }
        )

        await sender.start()
        let generation = sender.currentGeneration
        for frameNumber in 702 ... 704 {
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

        try await waitForStreamPacketSubmissionCount(submittedPackets, expectedCount: 3)

        #expect(submittedPackets.read { $0.map(\.frameNumber) } == [702, 703, 704])
        let telemetry = await sender.telemetrySnapshot
        #expect(telemetry.stalePacketDrops == 0)
        #expect(sender.queuedByteCount == 0)

        await sender.stop()
    }

    @Test("Repeated local deadline drops hold later P-frames until keyframe")
    func repeatedLocalDeadlineDropsHoldLaterPFramesUntilKeyframe() async throws {
        let submittedPackets = Locked<[StreamPacketSenderSubmittedPacket]>([])
        let dependencyDropCount = Locked(0)
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
                onComplete(nil)
            },
            onDependencyFrameDropped: { _, _, _ in dependencyDropCount.withLock { $0 += 1 } }
        )

        await sender.start()
        let generation = sender.currentGeneration
        for frameNumber in 401 ... 403 {
            sender.enqueue(
                makeStreamPacketWorkItem(
                    payload: makeStreamPacketPayload(byteCount: 128),
                    streamID: 46,
                    frameNumber: UInt32(frameNumber),
                    sequenceNumberStart: UInt32(frameNumber * 10),
                    generation: generation,
                    sendDeadline: CFAbsoluteTimeGetCurrent() - 0.001
                )
            )
        }

        try await Task.sleep(for: .milliseconds(50))

        sender.enqueue(
            makeStreamPacketWorkItem(
                payload: makeStreamPacketPayload(byteCount: 128),
                streamID: 46,
                frameNumber: 404,
                sequenceNumberStart: 4040,
                generation: generation
            )
        )
        try await Task.sleep(for: .milliseconds(50))

        let telemetry = await sender.telemetrySnapshot
        #expect(telemetry.stalePacketDrops == 3)
        #expect(telemetry.senderLocalDeadlineDrops == 3)
        #expect(telemetry.nonKeyframeHoldDrops == 1)
        #expect(submittedPackets.read { $0.isEmpty })
        #expect(dependencyDropCount.read { $0 == 1 })
        #expect(await sender.requiresDependencyRecoveryKeyframe())

        await sender.stop()
    }

    @Test("Started non-keyframes complete after deadline")
    func startedNonKeyframesCompleteAfterDeadline() async throws {
        let submittedPackets = Locked<[StreamPacketSenderSubmittedPacket]>([])
        let dependencyDropCount = Locked(0)
        let sender = StreamPacketSender(
            maxPayloadSize: 512,
            sendPacket: { packet, onComplete in
                guard let header = FrameHeader.deserialize(from: packet) else {
                    Issue.record("Failed to deserialize submitted packet")
                    onComplete(nil)
                    return
                }
                let isFirstSubmission = submittedPackets.withLock { packets in
                    packets.append(StreamPacketSenderSubmittedPacket(frameNumber: header.frameNumber))
                    return packets.count == 1
                }
                if isFirstSubmission {
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
        await sender.setTargetBitrateBps(2_000_000)
        let generation = sender.currentGeneration
        sender.enqueue(
            makeStreamPacketWorkItem(
                payload: makeStreamPacketPayload(byteCount: 1024),
                streamID: 47,
                frameNumber: 410,
                sequenceNumberStart: 4100,
                generation: generation,
                sendDeadline: CFAbsoluteTimeGetCurrent() + 0.015
            )
        )

        try await waitForStreamPacketSubmissionCount(submittedPackets, expectedCount: 2)
        try await Task.sleep(for: .milliseconds(80))

        let telemetry = await sender.telemetrySnapshot
        #expect(telemetry.senderLocalDeadlineDrops == 0)
        #expect(telemetry.stalePacketDrops == 0)
        #expect(submittedPackets.read { $0.map(\.frameNumber) } == [410, 410])
        #expect(dependencyDropCount.read { $0 == 0 })
        #expect(await !sender.requiresDependencyRecoveryKeyframe())

        await sender.stop()
    }

    @Test("Expired P-frame after queued keyframe holds later P-frames")
    func expiredPFrameAfterQueuedKeyframeHoldsLaterPFrames() async throws {
        let submittedPackets = Locked<[StreamPacketSenderSubmittedPacket]>([])
        let dependencyDropCount = Locked(0)
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
                onComplete(nil)
            },
            onDependencyFrameDropped: { _, _, _ in dependencyDropCount.withLock { $0 += 1 } }
        )

        await sender.start()
        let generation = sender.currentGeneration
        sender.enqueue(
            makeStreamPacketWorkItem(
                payload: makeStreamPacketPayload(byteCount: 1024),
                streamID: 48,
                frameNumber: 500,
                sequenceNumberStart: 5000,
                generation: generation,
                isKeyframe: true
            )
        )
        sender.enqueue(
            makeStreamPacketWorkItem(
                payload: makeStreamPacketPayload(byteCount: 128),
                streamID: 48,
                frameNumber: 501,
                sequenceNumberStart: 5100,
                generation: generation,
                sendDeadline: CFAbsoluteTimeGetCurrent() - 0.001
            )
        )
        sender.enqueue(
            makeStreamPacketWorkItem(
                payload: makeStreamPacketPayload(byteCount: 128),
                streamID: 48,
                frameNumber: 502,
                sequenceNumberStart: 5200,
                generation: generation
            )
        )

        try await waitForStreamPacketSubmissionCount(submittedPackets, expectedCount: 2)
        try await Task.sleep(for: .milliseconds(50))
        let telemetry = await sender.telemetrySnapshot
        #expect(telemetry.stalePacketDrops == 1)
        #expect(telemetry.senderLocalDeadlineDrops == 1)
        #expect(telemetry.nonKeyframeHoldDrops == 1)
        #expect(dependencyDropCount.read { $0 == 1 })
        #expect(submittedPackets.read { $0.map(\.frameNumber) } == [500, 500])
        #expect(await sender.requiresDependencyRecoveryKeyframe())

        await sender.stop()
    }

    @Test("Expired P-frame after queued keyframe opens recovery off AWDL")
    func expiredPFrameAfterQueuedKeyframeOpensRecoveryOffAwdl() async throws {
        let submittedPackets = Locked<[StreamPacketSenderSubmittedPacket]>([])
        let dependencyDropCount = Locked(0)
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
                onComplete(nil)
            },
            onDependencyFrameDropped: { _, _, _ in dependencyDropCount.withLock { $0 += 1 } }
        )

        await sender.start()
        let generation = sender.currentGeneration
        sender.enqueue(
            makeStreamPacketWorkItem(
                payload: makeStreamPacketPayload(byteCount: 1024),
                streamID: 49,
                frameNumber: 600,
                sequenceNumberStart: 6000,
                generation: generation,
                isKeyframe: true
            )
        )
        sender.enqueue(
            makeStreamPacketWorkItem(
                payload: makeStreamPacketPayload(byteCount: 128),
                streamID: 49,
                frameNumber: 601,
                sequenceNumberStart: 6100,
                generation: generation,
                sendDeadline: CFAbsoluteTimeGetCurrent() - 0.001
            )
        )
        sender.enqueue(
            makeStreamPacketWorkItem(
                payload: makeStreamPacketPayload(byteCount: 128),
                streamID: 49,
                frameNumber: 602,
                sequenceNumberStart: 6200,
                generation: generation
            )
        )

        try await waitForStreamPacketSubmissionCount(submittedPackets, expectedCount: 2)
        try await Task.sleep(for: .milliseconds(50))
        let telemetry = await sender.telemetrySnapshot
        #expect(telemetry.stalePacketDrops == 1)
        #expect(telemetry.senderLocalDeadlineDrops == 1)
        #expect(telemetry.nonKeyframeHoldDrops == 1)
        #expect(dependencyDropCount.read { $0 == 1 })
        #expect(submittedPackets.read { $0.map(\.frameNumber) } == [600, 600])
        #expect(await sender.requiresDependencyRecoveryKeyframe())

        await sender.stop()
    }
}
#endif
