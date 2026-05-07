//
//  StreamPacketSenderRegressionTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/30/26.
//

#if os(macOS)
@testable import MirageKitHost
import CoreGraphics
import CoreMedia
import Foundation
import MirageKit
import Testing

@Suite("Stream Packet Sender Regression")
struct StreamPacketSenderRegressionTests {
    @Test("Sender-local stale P-frames do not enter dependency loss")
    func senderLocalStalePFramesDoNotEnterDependencyLoss() async {
        let dependencyDrops = Locked<[DependencyDrop]>([])
        let sender = StreamPacketSender(
            maxPayloadSize: 512,
            sendPacket: { _, onComplete in onComplete(nil) },
            onDependencyFrameDropped: { streamID, frameNumber, reason in
                dependencyDrops.withLock {
                    $0.append(DependencyDrop(streamID: streamID, frameNumber: frameNumber, reason: reason))
                }
            }
        )

        await sender.start()
        let generation = sender.currentGenerationSnapshot()
        let expiredDeadline = CFAbsoluteTimeGetCurrent() - 1
        for frameNumber in 1 ... 2 {
            sender.enqueue(
                makeWorkItem(
                    payload: makePayload(byteCount: 128),
                    streamID: 40,
                    frameNumber: UInt32(frameNumber),
                    sequenceNumberStart: UInt32(frameNumber * 10),
                    generation: generation,
                    sendDeadline: expiredDeadline
                )
            )
        }

        sender.enqueue(
            makeWorkItem(
                payload: makePayload(byteCount: 128),
                streamID: 40,
                frameNumber: 3,
                sequenceNumberStart: 30,
                generation: generation,
                sendDeadline: expiredDeadline
            )
        )

        #expect(dependencyDrops.read { $0.isEmpty })
        let localSnapshot = await sender.telemetrySnapshot()
        #expect(localSnapshot.senderLocalDeadlineDrops == 3)
        #expect(localSnapshot.stalePacketDrops == 3)
        await sender.stop()
    }

    @Test("Keyframe submission clears non-keyframe hold before send completion")
    func keyframeSubmissionClearsHoldBeforeCompletion() async throws {
        let submittedPackets = Locked<[SubmittedPacket]>([])
        let pendingCompletions = Locked<[PendingSendCompletion]>([])
        let sender = StreamPacketSender(
            maxPayloadSize: 512,
            sendPacket: { packet, onComplete in
                guard let header = FrameHeader.deserialize(from: packet) else {
                    Issue.record("Failed to deserialize submitted packet")
                    onComplete(nil)
                    return
                }
                submittedPackets.withLock {
                    $0.append(SubmittedPacket(frameNumber: header.frameNumber, sequenceNumber: header.sequenceNumber))
                }
                pendingCompletions.withLock { $0.append(PendingSendCompletion(onComplete: onComplete)) }
            }
        )

        await sender.start()
        let generation = sender.currentGenerationSnapshot()
        sender.enqueue(
            makeWorkItem(
                payload: makePayload(byteCount: 1024),
                streamID: 41,
                frameNumber: 70,
                sequenceNumberStart: 700,
                generation: generation,
                isKeyframe: true
            )
        )

        try await waitForSubmissionCount(submittedPackets, expectedCount: 2)

        sender.enqueue(
            makeWorkItem(
                payload: makePayload(byteCount: 128),
                streamID: 41,
                frameNumber: 71,
                sequenceNumberStart: 800,
                generation: generation
            )
        )

        try await waitForSubmissionCount(submittedPackets, expectedCount: 3)

        let frameNumbers = submittedPackets.read { $0.map(\.frameNumber) }
        #expect(frameNumbers == [70, 70, 71])
        #expect((await sender.telemetrySnapshot()).nonKeyframeHoldDrops == 0)

        completePendingSends(pendingCompletions)
        try await waitForQueuedBytesToDrain(sender)
        await sender.stop()
    }

    @Test("Delayed keyframe completions do not drop following P-frames")
    func delayedKeyframeCompletionsDoNotDropFollowingPFrames() async throws {
        let submittedPackets = Locked<[SubmittedPacket]>([])
        let pendingCompletions = Locked<[PendingSendCompletion]>([])
        let sender = StreamPacketSender(
            maxPayloadSize: 512,
            sendPacket: { packet, onComplete in
                guard let header = FrameHeader.deserialize(from: packet) else {
                    Issue.record("Failed to deserialize submitted packet")
                    onComplete(nil)
                    return
                }
                submittedPackets.withLock {
                    $0.append(SubmittedPacket(frameNumber: header.frameNumber, sequenceNumber: header.sequenceNumber))
                }
                pendingCompletions.withLock { $0.append(PendingSendCompletion(onComplete: onComplete)) }
            }
        )

        await sender.start()
        let generation = sender.currentGenerationSnapshot()
        sender.enqueue(
            makeWorkItem(
                payload: makePayload(byteCount: 1024),
                streamID: 42,
                frameNumber: 90,
                sequenceNumberStart: 900,
                generation: generation,
                isKeyframe: true
            )
        )
        for frameNumber in 91 ... 96 {
            sender.enqueue(
                makeWorkItem(
                    payload: makePayload(byteCount: 128),
                    streamID: 42,
                    frameNumber: UInt32(frameNumber),
                    sequenceNumberStart: UInt32(frameNumber * 10),
                    generation: generation
                )
            )
        }

        try await waitForSubmissionCount(submittedPackets, expectedCount: 8)

        let frameNumbers = submittedPackets.read { $0.map(\.frameNumber) }
        #expect(frameNumbers == [90, 90, 91, 92, 93, 94, 95, 96])
        #expect((await sender.telemetrySnapshot()).nonKeyframeHoldDrops == 0)

        completePendingSends(pendingCompletions)
        try await waitForQueuedBytesToDrain(sender)
        await sender.stop()
    }

    @Test("Consumed telemetry windows clear send delay aggregates")
    func consumedTelemetryWindowsClearSendDelayAggregates() async throws {
        let sender = StreamPacketSender(
            maxPayloadSize: 512,
            sendPacket: { _, onComplete in
                onComplete(nil)
            }
        )

        await sender.start()
        let generation = sender.currentGenerationSnapshot()
        sender.enqueue(
            makeWorkItem(
                payload: makePayload(byteCount: 256),
                streamID: 43,
                frameNumber: 101,
                sequenceNumberStart: 1_010,
                generation: generation,
                encodedAt: CFAbsoluteTimeGetCurrent() - 0.02
            )
        )

        _ = try await waitForTelemetry(
            sender,
            timeoutSeconds: 2.0
        ) { snapshot in
            snapshot.sendStartDelayAverageMs > 0 &&
                snapshot.sendCompletionAverageMs > 0 &&
                snapshot.nonKeyframeSendStartDelayAverageMs > 0 &&
                snapshot.nonKeyframeSendCompletionAverageMs > 0
        }

        let firstWindow = await sender.consumeTelemetrySnapshot()
        #expect(firstWindow.sendStartDelayAverageMs > 0)
        #expect(firstWindow.sendCompletionAverageMs > 0)
        #expect(firstWindow.nonKeyframeSendStartDelayAverageMs > 0)
        #expect(firstWindow.nonKeyframeSendCompletionAverageMs > 0)

        let secondWindow = await sender.consumeTelemetrySnapshot()
        #expect(secondWindow.sendStartDelayAverageMs == 0)
        #expect(secondWindow.sendCompletionAverageMs == 0)
        #expect(secondWindow.nonKeyframeSendStartDelayAverageMs == 0)
        #expect(secondWindow.nonKeyframeSendCompletionAverageMs == 0)

        await sender.stop()
    }

    @Test("Consumed telemetry windows clear transient generation-abort drops")
    func consumedTelemetryWindowsClearTransientGenerationAbortDrops() async throws {
        let sender = StreamPacketSender(
            maxPayloadSize: 512,
            sendPacket: { _, onComplete in
                onComplete(nil)
            }
        )

        await sender.start()
        let generation = sender.currentGenerationSnapshot()
        sender.enqueue(
            makeWorkItem(
                payload: makePayload(byteCount: 128),
                streamID: 44,
                frameNumber: 201,
                sequenceNumberStart: 2_010,
                generation: generation &+ 1
            )
        )

        _ = try await waitForTelemetry(
            sender,
            timeoutSeconds: 2.0
        ) { snapshot in
            snapshot.generationAbortDrops == 1
        }

        let firstWindow = await sender.consumeTelemetrySnapshot()
        #expect(firstWindow.generationAbortDrops == 1)

        let secondWindow = await sender.consumeTelemetrySnapshot()
        #expect(secondWindow.generationAbortDrops == 0)

        await sender.stop()
    }

    @Test("Keyframe telemetry does not populate non-keyframe delay buckets")
    func keyframeTelemetryDoesNotPopulateNonKeyframeDelayBuckets() async throws {
        let sender = StreamPacketSender(
            maxPayloadSize: 512,
            sendPacket: { _, onComplete in
                onComplete(nil)
            }
        )

        await sender.start()
        let generation = sender.currentGenerationSnapshot()
        sender.enqueue(
            makeWorkItem(
                payload: makePayload(byteCount: 1_024),
                streamID: 45,
                frameNumber: 301,
                sequenceNumberStart: 3_010,
                generation: generation,
                isKeyframe: true,
                encodedAt: CFAbsoluteTimeGetCurrent() - 0.02
            )
        )

        let snapshot = try await waitForTelemetry(
            sender,
            timeoutSeconds: 2.0
        ) { snapshot in
            snapshot.sendCompletionAverageMs > 0
        }

        #expect(snapshot.sendStartDelayAverageMs > 0)
        #expect(snapshot.sendCompletionAverageMs > 0)
        #expect(snapshot.nonKeyframeSendStartDelayAverageMs == 0)
        #expect(snapshot.nonKeyframeSendCompletionAverageMs == 0)
        #expect(snapshot.nonKeyframeSendStartDelayMaxMs == 0)
        #expect(snapshot.nonKeyframeSendCompletionMaxMs == 0)

        await sender.stop()
    }

    @Test("Expired non-keyframes are dropped before packet submission")
    func expiredNonKeyframesDropBeforePacketSubmission() async throws {
        let submittedPackets = Locked<[SubmittedPacket]>([])
        let sender = StreamPacketSender(
            maxPayloadSize: 512,
            sendPacket: { packet, onComplete in
                guard let header = FrameHeader.deserialize(from: packet) else {
                    Issue.record("Failed to deserialize submitted packet")
                    onComplete(nil)
                    return
                }
                submittedPackets.withLock {
                    $0.append(SubmittedPacket(frameNumber: header.frameNumber, sequenceNumber: header.sequenceNumber))
                }
                onComplete(nil)
            }
        )

        await sender.start()
        let generation = sender.currentGenerationSnapshot()
        sender.enqueue(
            makeWorkItem(
                payload: makePayload(byteCount: 128),
                streamID: 45,
                frameNumber: 302,
                sequenceNumberStart: 3_010,
                generation: generation,
                sendDeadline: CFAbsoluteTimeGetCurrent() - 0.001
            )
        )

        _ = try await waitForTelemetry(
            sender,
            timeoutSeconds: 2.0
        ) { snapshot in
            snapshot.stalePacketDrops == 1
        }

        #expect(submittedPackets.read { $0.isEmpty })
        #expect(sender.queuedBytesSnapshot() == 0)

        await sender.stop()
    }

    @Test("Default non-keyframe deadline expires stale dependency frames")
    func defaultNonKeyframeDeadlineExpiresStaleDependencyFrame() async throws {
        let submittedPackets = Locked<[SubmittedPacket]>([])
        let sender = StreamPacketSender(
            maxPayloadSize: 512,
            sendPacket: { packet, onComplete in
                guard let header = FrameHeader.deserialize(from: packet) else {
                    Issue.record("Failed to deserialize submitted packet")
                    onComplete(nil)
                    return
                }
                submittedPackets.withLock {
                    $0.append(SubmittedPacket(frameNumber: header.frameNumber, sequenceNumber: header.sequenceNumber))
                }
                onComplete(nil)
            }
        )

        await sender.start()
        let generation = sender.currentGenerationSnapshot()
        sender.enqueue(
            makeWorkItem(
                payload: makePayload(byteCount: 128),
                streamID: 45,
                frameNumber: 303,
                sequenceNumberStart: 3_020,
                generation: generation,
                encodedAt: CFAbsoluteTimeGetCurrent() - 10
            )
        )

        _ = try await waitForTelemetry(
            sender,
            timeoutSeconds: 2.0
        ) { snapshot in
            snapshot.stalePacketDrops == 1
        }

        #expect(submittedPackets.read { $0.isEmpty })
        #expect(sender.queuedBytesSnapshot() == 0)

        await sender.stop()
    }

    @Test("Repeated local expired dependency frames stay local")
    func repeatedLocalExpiredDependencyFramesStayLocal() async throws {
        let submittedPackets = Locked<[SubmittedPacket]>([])
        let dependencyDrops = Locked<[DependencyDrop]>([])
        let sender = StreamPacketSender(
            maxPayloadSize: 512,
            sendPacket: { packet, onComplete in
                guard let header = FrameHeader.deserialize(from: packet) else {
                    Issue.record("Failed to deserialize submitted packet")
                    onComplete(nil)
                    return
                }
                submittedPackets.withLock {
                    $0.append(SubmittedPacket(frameNumber: header.frameNumber, sequenceNumber: header.sequenceNumber))
                }
                onComplete(nil)
            },
            onDependencyFrameDropped: { streamID, frameNumber, reason in
                dependencyDrops.withLock {
                    $0.append(DependencyDrop(streamID: streamID, frameNumber: frameNumber, reason: reason))
                }
            }
        )

        await sender.start()
        let generation = sender.currentGenerationSnapshot()
        for frameNumber in 401 ... 403 {
            sender.enqueue(
                makeWorkItem(
                    payload: makePayload(byteCount: 128),
                    streamID: 46,
                    frameNumber: UInt32(frameNumber),
                    sequenceNumberStart: UInt32(frameNumber * 10),
                    generation: generation,
                    sendDeadline: CFAbsoluteTimeGetCurrent() - 0.001
                )
            )
        }

        _ = try await waitForTelemetry(
            sender,
            timeoutSeconds: 2.0
        ) { snapshot in
            snapshot.stalePacketDrops == 3 &&
                snapshot.senderLocalDeadlineDrops == 3
        }

        sender.enqueue(
            makeWorkItem(
                payload: makePayload(byteCount: 128),
                streamID: 46,
                frameNumber: 404,
                sequenceNumberStart: 4_040,
                generation: generation
            )
        )
        try await waitForSubmissionCount(submittedPackets, expectedCount: 1)

        let drops = dependencyDrops.read { $0 }
        #expect(drops.isEmpty)

        sender.enqueue(
            makeWorkItem(
                payload: makePayload(byteCount: 128),
                streamID: 46,
                frameNumber: 405,
                sequenceNumberStart: 4_050,
                generation: generation,
                isKeyframe: true
            )
        )
        try await waitForSubmissionCount(submittedPackets, expectedCount: 2)

        sender.enqueue(
            makeWorkItem(
                payload: makePayload(byteCount: 128),
                streamID: 46,
                frameNumber: 406,
                sequenceNumberStart: 4_060,
                generation: generation
            )
        )
        try await waitForSubmissionCount(submittedPackets, expectedCount: 3)

        #expect(submittedPackets.read { $0.map(\.frameNumber) } == [404, 405, 406])

        await sender.stop()
    }

    @Test("Expired P-frame behind queued keyframe stays local")
    func expiredPFrameBehindQueuedKeyframeStaysLocal() async throws {
        let submittedPackets = Locked<[SubmittedPacket]>([])
        let dependencyDrops = Locked<[DependencyDrop]>([])
        let sender = StreamPacketSender(
            maxPayloadSize: 512,
            sendPacket: { packet, onComplete in
                guard let header = FrameHeader.deserialize(from: packet) else {
                    Issue.record("Failed to deserialize submitted packet")
                    onComplete(nil)
                    return
                }
                submittedPackets.withLock {
                    $0.append(SubmittedPacket(frameNumber: header.frameNumber, sequenceNumber: header.sequenceNumber))
                }
                onComplete(nil)
            },
            onDependencyFrameDropped: { streamID, frameNumber, reason in
                dependencyDrops.withLock {
                    $0.append(DependencyDrop(streamID: streamID, frameNumber: frameNumber, reason: reason))
                }
            }
        )

        await sender.start()
        let generation = sender.currentGenerationSnapshot()
        sender.enqueue(
            makeWorkItem(
                payload: makePayload(byteCount: 1024),
                streamID: 48,
                frameNumber: 500,
                sequenceNumberStart: 5_000,
                generation: generation,
                isKeyframe: true
            )
        )
        sender.enqueue(
            makeWorkItem(
                payload: makePayload(byteCount: 128),
                streamID: 48,
                frameNumber: 501,
                sequenceNumberStart: 5_100,
                generation: generation,
                sendDeadline: CFAbsoluteTimeGetCurrent() - 0.001
            )
        )
        sender.enqueue(
            makeWorkItem(
                payload: makePayload(byteCount: 128),
                streamID: 48,
                frameNumber: 502,
                sequenceNumberStart: 5_200,
                generation: generation
            )
        )

        try await waitForSubmissionCount(submittedPackets, expectedCount: 3)
        let telemetry = await sender.telemetrySnapshot()
        #expect(telemetry.stalePacketDrops == 1)
        #expect(telemetry.nonKeyframeHoldDrops == 0)
        #expect(dependencyDrops.read { $0.isEmpty })
        #expect(submittedPackets.read { $0.map(\.frameNumber) } == [500, 500, 502])

        await sender.stop()
    }

    @Test("Infinite non-keyframe deadline preserves dependency frame")
    func infiniteNonKeyframeDeadlinePreservesDependencyFrame() async throws {
        let submittedPackets = Locked<[SubmittedPacket]>([])
        let sender = StreamPacketSender(
            maxPayloadSize: 512,
            sendPacket: { packet, onComplete in
                guard let header = FrameHeader.deserialize(from: packet) else {
                    Issue.record("Failed to deserialize submitted packet")
                    onComplete(nil)
                    return
                }
                submittedPackets.withLock {
                    $0.append(SubmittedPacket(frameNumber: header.frameNumber, sequenceNumber: header.sequenceNumber))
                }
                onComplete(nil)
            }
        )

        await sender.start()
        let generation = sender.currentGenerationSnapshot()
        sender.enqueue(
            makeWorkItem(
                payload: makePayload(byteCount: 128),
                streamID: 45,
                frameNumber: 303,
                sequenceNumberStart: 3_020,
                generation: generation,
                encodedAt: CFAbsoluteTimeGetCurrent() - 10,
                sendDeadline: .greatestFiniteMagnitude
            )
        )

        try await waitForSubmissionCount(submittedPackets, expectedCount: 1)

        #expect(submittedPackets.read { $0.map(\.frameNumber) } == [303])
        #expect((await sender.telemetrySnapshot()).stalePacketDrops == 0)

        await sender.stop()
    }

    @Test("Newer current-generation keyframes supersede older queued keyframes")
    func newerCurrentGenerationKeyframesSupersedeOlderQueuedKeyframes() async throws {
        let submittedPackets = Locked<[SubmittedPacket]>([])
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
                    $0.append(SubmittedPacket(frameNumber: header.frameNumber, sequenceNumber: header.sequenceNumber))
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
        let generation = sender.currentGenerationSnapshot()
        sender.enqueue(
            makeWorkItem(
                payload: makePayload(byteCount: 16),
                streamID: 46,
                frameNumber: 300,
                sequenceNumberStart: 3_000,
                generation: generation
            )
        )
        try await waitForSubmissionCount(submittedPackets, expectedCount: 1)

        sender.enqueue(
            makeWorkItem(
                payload: makePayload(byteCount: 128),
                streamID: 46,
                frameNumber: 310,
                sequenceNumberStart: 3_100,
                generation: generation,
                isKeyframe: true
            )
        )
        sender.enqueue(
            makeWorkItem(
                payload: makePayload(byteCount: 128),
                streamID: 46,
                frameNumber: 311,
                sequenceNumberStart: 3_110,
                generation: generation,
                isKeyframe: true
            )
        )

        try await waitForSubmissionCount(submittedPackets, expectedCount: 2)
        let frameNumbers = submittedPackets.read { $0.map(\.frameNumber) }
        #expect(frameNumbers == [300, 311])
        #expect((await sender.telemetrySnapshot()).stalePacketDrops == 1)

        await sender.stop()
    }

    @Test("Stale-generation keyframes do not supersede current recovery keyframes")
    func staleGenerationKeyframesDoNotSupersedeCurrentRecoveryKeyframes() async throws {
        let submittedPackets = Locked<[SubmittedPacket]>([])
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
                    $0.append(SubmittedPacket(frameNumber: header.frameNumber, sequenceNumber: header.sequenceNumber))
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
        let generation = sender.currentGenerationSnapshot()
        sender.enqueue(
            makeWorkItem(
                payload: makePayload(byteCount: 16),
                streamID: 47,
                frameNumber: 400,
                sequenceNumberStart: 4_000,
                generation: generation
            )
        )
        try await waitForSubmissionCount(submittedPackets, expectedCount: 1)

        sender.enqueue(
            makeWorkItem(
                payload: makePayload(byteCount: 128),
                streamID: 47,
                frameNumber: 401,
                sequenceNumberStart: 4_010,
                generation: generation,
                isKeyframe: true
            )
        )
        sender.enqueue(
            makeWorkItem(
                payload: makePayload(byteCount: 128),
                streamID: 47,
                frameNumber: 499,
                sequenceNumberStart: 4_990,
                generation: generation &- 1,
                isKeyframe: true
            )
        )

        try await waitForSubmissionCount(submittedPackets, expectedCount: 2)
        _ = try await waitForTelemetry(
            sender,
            timeoutSeconds: 2.0
        ) { snapshot in
            snapshot.generationAbortDrops == 1
        }

        let frameNumbers = submittedPackets.read { $0.map(\.frameNumber) }
        #expect(frameNumbers == [400, 401])

        await sender.stop()
    }

    private func waitForSubmissionCount(
        _ submittedPackets: Locked<[SubmittedPacket]>,
        expectedCount: Int,
        timeoutSeconds: TimeInterval = 2.0
    ) async throws {
        let deadline = CFAbsoluteTimeGetCurrent() + timeoutSeconds
        while submittedPackets.read({ $0.count }) < expectedCount, CFAbsoluteTimeGetCurrent() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(submittedPackets.read({ $0.count }) == expectedCount)
    }

    private func waitForQueuedBytesToDrain(
        _ sender: StreamPacketSender,
        timeoutSeconds: TimeInterval = 2.0
    ) async throws {
        let deadline = CFAbsoluteTimeGetCurrent() + timeoutSeconds
        while sender.queuedBytesSnapshot() > 0, CFAbsoluteTimeGetCurrent() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(sender.queuedBytesSnapshot() == 0)
    }

    private func waitForTelemetry(
        _ sender: StreamPacketSender,
        timeoutSeconds: TimeInterval = 2.0,
        until predicate: @escaping (StreamPacketSender.TelemetrySnapshot) -> Bool
    ) async throws -> StreamPacketSender.TelemetrySnapshot {
        let deadline = CFAbsoluteTimeGetCurrent() + timeoutSeconds
        while CFAbsoluteTimeGetCurrent() < deadline {
            let snapshot = await sender.telemetrySnapshot()
            if predicate(snapshot) {
                return snapshot
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let snapshot = await sender.telemetrySnapshot()
        Issue.record("Timed out waiting for telemetry condition")
        return snapshot
    }

    private func completePendingSends(_ pendingCompletions: Locked<[PendingSendCompletion]>) {
        pendingCompletions.withLock { completions in
            completions.forEach { $0.complete(nil) }
            completions.removeAll(keepingCapacity: false)
        }
    }

    private func makePayload(byteCount: Int) -> Data {
        Data((0 ..< byteCount).map { UInt8(truncatingIfNeeded: $0) })
    }

    private func makeWorkItem(
        payload: Data,
        streamID: StreamID,
        frameNumber: UInt32,
        sequenceNumberStart: UInt32,
        generation: UInt32,
        isKeyframe: Bool = false,
        encodedAt: CFAbsoluteTime = CFAbsoluteTimeGetCurrent(),
        sendDeadline: CFAbsoluteTime? = nil
    ) -> StreamPacketSender.WorkItem {
        StreamPacketSender.WorkItem(
            encodedData: payload,
            frameByteCount: payload.count,
            isKeyframe: isKeyframe,
            presentationTime: CMTime(seconds: Double(frameNumber), preferredTimescale: 600),
            contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            streamID: streamID,
            frameNumber: frameNumber,
            sequenceNumberStart: sequenceNumberStart,
            additionalFlags: [],
            dimensionToken: 0,
            epoch: 0,
            fecBlockSize: 0,
            wireBytes: payload.count,
            logPrefix: "test",
            generation: generation,
            encodedAt: encodedAt,
            sendDeadline: sendDeadline,
            pacingOverride: nil
        )
    }
}

private struct SubmittedPacket: Sendable {
    let frameNumber: UInt32
    let sequenceNumber: UInt32
}

private struct DependencyDrop: Sendable {
    let streamID: StreamID
    let frameNumber: UInt32
    let reason: StreamPacketSender.DependencyFrameDropReason
}

private final class PendingSendCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var onComplete: (@Sendable (Error?) -> Void)?

    init(onComplete: @escaping @Sendable (Error?) -> Void) {
        self.onComplete = onComplete
    }

    func complete(_ error: Error?) {
        lock.lock()
        let onComplete = self.onComplete
        self.onComplete = nil
        lock.unlock()
        onComplete?(error)
    }
}
#endif
