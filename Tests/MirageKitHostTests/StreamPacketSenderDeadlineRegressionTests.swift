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
    @Test("Expired non-keyframes are dropped before packet submission")
    func expiredNonKeyframesDropBeforePacketSubmission() async throws {
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
                frameNumber: 302,
                sequenceNumberStart: 3010,
                generation: generation,
                sendDeadline: CFAbsoluteTimeGetCurrent() - 0.001
            )
        )

        _ = try await waitForStreamPacketTelemetry(
            sender,
            timeout: .seconds(2)
        ) { snapshot in
            snapshot.stalePacketDrops == 1
        }

        #expect(submittedPackets.read { $0.isEmpty })
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

    @Test("Non-keyframe drops instead of pacing past sender deadline")
    func nonKeyframeDropsInsteadOfPacingPastSenderDeadline() async throws {
        let submittedPackets = Locked<[StreamPacketSenderSubmittedPacket]>([])
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
            }
        )

        await sender.start()
        await sender.setTargetBitrateBps(8_000)
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

        let telemetry = try await waitForStreamPacketTelemetry(
            sender,
            timeout: .seconds(2)
        ) { snapshot in
            snapshot.stalePacketDrops == 1 &&
                snapshot.senderLocalDeadlineDrops == 1
        }

        #expect(telemetry.stalePacketDrops == 1)
        #expect(submittedPackets.read { $0.isEmpty })
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

    @Test("Repeated local expired dependency frames stay local")
    func repeatedLocalExpiredDependencyFramesStayLocal() async throws {
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

        _ = try await waitForStreamPacketTelemetry(
            sender,
            timeout: .seconds(2)
        ) { snapshot in
            snapshot.stalePacketDrops == 3 &&
                snapshot.senderLocalDeadlineDrops == 3
        }

        sender.enqueue(
            makeStreamPacketWorkItem(
                payload: makeStreamPacketPayload(byteCount: 128),
                streamID: 46,
                frameNumber: 404,
                sequenceNumberStart: 4040,
                generation: generation
            )
        )
        try await waitForStreamPacketSubmissionCount(submittedPackets, expectedCount: 1)

        #expect(dependencyDropCount.read { $0 == 0 })

        sender.enqueue(
            makeStreamPacketWorkItem(
                payload: makeStreamPacketPayload(byteCount: 128),
                streamID: 46,
                frameNumber: 405,
                sequenceNumberStart: 4050,
                generation: generation,
                isKeyframe: true
            )
        )
        try await waitForStreamPacketSubmissionCount(submittedPackets, expectedCount: 2)

        sender.enqueue(
            makeStreamPacketWorkItem(
                payload: makeStreamPacketPayload(byteCount: 128),
                streamID: 46,
                frameNumber: 406,
                sequenceNumberStart: 4060,
                generation: generation
            )
        )
        try await waitForStreamPacketSubmissionCount(submittedPackets, expectedCount: 3)

        #expect(submittedPackets.read { $0.map(\.frameNumber) } == [404, 405, 406])

        await sender.stop()
    }

    @Test("Expired P-frame behind queued keyframe stays local")
    func expiredPFrameBehindQueuedKeyframeStaysLocal() async throws {
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

        try await waitForStreamPacketSubmissionCount(submittedPackets, expectedCount: 3)
        let telemetry = await sender.telemetrySnapshot
        #expect(telemetry.stalePacketDrops == 1)
        #expect(telemetry.nonKeyframeHoldDrops == 0)
        #expect(dependencyDropCount.read { $0 == 0 })
        #expect(submittedPackets.read { $0.map(\.frameNumber) } == [500, 500, 502])

        await sender.stop()
    }
}
#endif
