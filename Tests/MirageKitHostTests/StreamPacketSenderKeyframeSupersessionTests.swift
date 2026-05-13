//
//  StreamPacketSenderKeyframeSupersessionTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

#if os(macOS)
@testable import MirageKitHost
import CoreGraphics
import CoreMedia
import Foundation
import MirageKit
import Testing

@Suite("Stream Packet Sender Keyframe Supersession")
struct StreamPacketSenderKeyframeSupersessionTests {
    @Test("Infinite non-keyframe deadline preserves dependency frame")
    func infiniteNonKeyframeDeadlinePreservesDependencyFrame() async throws {
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
                encodedAt: CFAbsoluteTimeGetCurrent() - 10,
                sendDeadline: .greatestFiniteMagnitude
            )
        )

        try await waitForStreamPacketSubmissionCount(submittedPackets, expectedCount: 1)

        #expect(submittedPackets.read { $0.map(\.frameNumber) } == [303])
        #expect(await (sender.telemetrySnapshot).stalePacketDrops == 0)

        await sender.stop()
    }

    @Test("Newer current-generation keyframes supersede older queued keyframes")
    func newerCurrentGenerationKeyframesSupersedeOlderQueuedKeyframes() async throws {
        let submittedPackets = Locked<[StreamPacketSenderSubmittedPacket]>([])
        let blockedFirstPacket = Locked(false)
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
                    guard !didBlock, header.frameNumber == 300 else { return false }
                    didBlock = true
                    return true
                }
                if shouldBlock { Thread.sleep(forTimeInterval: 0.05) }
                onComplete(nil)
            }
        )

        await sender.start()
        let generation = sender.currentGeneration
        sender.enqueue(
            makeStreamPacketWorkItem(
                payload: makeStreamPacketPayload(byteCount: 16),
                streamID: 46,
                frameNumber: 300,
                sequenceNumberStart: 3000,
                generation: generation
            )
        )
        try await waitForStreamPacketSubmissionCount(submittedPackets, expectedCount: 1)

        sender.enqueue(
            makeStreamPacketWorkItem(
                payload: makeStreamPacketPayload(byteCount: 128),
                streamID: 46,
                frameNumber: 310,
                sequenceNumberStart: 3100,
                generation: generation,
                isKeyframe: true
            )
        )
        sender.enqueue(
            makeStreamPacketWorkItem(
                payload: makeStreamPacketPayload(byteCount: 128),
                streamID: 46,
                frameNumber: 311,
                sequenceNumberStart: 3110,
                generation: generation,
                isKeyframe: true
            )
        )

        try await waitForStreamPacketSubmissionCount(submittedPackets, expectedCount: 2)
        let frameNumbers = submittedPackets.read { $0.map(\.frameNumber) }
        #expect(frameNumbers == [300, 311])
        #expect(await (sender.telemetrySnapshot).stalePacketDrops == 1)

        await sender.stop()
    }

    @Test("Stale-generation keyframes do not supersede current recovery keyframes")
    func staleGenerationKeyframesDoNotSupersedeCurrentRecoveryKeyframes() async throws {
        let submittedPackets = Locked<[StreamPacketSenderSubmittedPacket]>([])
        let blockedFirstPacket = Locked(false)
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
                    guard !didBlock, header.frameNumber == 400 else { return false }
                    didBlock = true
                    return true
                }
                if shouldBlock { Thread.sleep(forTimeInterval: 0.05) }
                onComplete(nil)
            }
        )

        await sender.start()
        await sender.bumpGeneration(reason: "test current recovery keyframe")
        let generation = sender.currentGeneration
        sender.enqueue(
            makeStreamPacketWorkItem(
                payload: makeStreamPacketPayload(byteCount: 16),
                streamID: 47,
                frameNumber: 400,
                sequenceNumberStart: 4000,
                generation: generation
            )
        )
        try await waitForStreamPacketSubmissionCount(submittedPackets, expectedCount: 1)

        sender.enqueue(
            makeStreamPacketWorkItem(
                payload: makeStreamPacketPayload(byteCount: 128),
                streamID: 47,
                frameNumber: 401,
                sequenceNumberStart: 4010,
                generation: generation,
                isKeyframe: true
            )
        )
        sender.enqueue(
            makeStreamPacketWorkItem(
                payload: makeStreamPacketPayload(byteCount: 128),
                streamID: 47,
                frameNumber: 499,
                sequenceNumberStart: 4990,
                generation: generation &- 1,
                isKeyframe: true
            )
        )

        try await waitForStreamPacketSubmissionCount(submittedPackets, expectedCount: 2)
        _ = try await waitForStreamPacketTelemetry(
            sender,
            timeout: .seconds(2)
        ) { snapshot in
            snapshot.generationAbortDrops == 1
        }

        let frameNumbers = submittedPackets.read { $0.map(\.frameNumber) }
        #expect(frameNumbers == [400, 401])

        await sender.stop()
    }
}
#endif
