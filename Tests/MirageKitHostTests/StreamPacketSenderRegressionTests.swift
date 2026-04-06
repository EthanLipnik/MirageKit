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
                snapshot.sendCompletionAverageMs > 0
        }

        let firstWindow = await sender.consumeTelemetrySnapshot()
        #expect(firstWindow.sendStartDelayAverageMs > 0)
        #expect(firstWindow.sendCompletionAverageMs > 0)

        let secondWindow = await sender.consumeTelemetrySnapshot()
        #expect(secondWindow.sendStartDelayAverageMs == 0)
        #expect(secondWindow.sendCompletionAverageMs == 0)

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
        encodedAt: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
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
            pacingOverride: nil
        )
    }
}

private struct SubmittedPacket: Sendable {
    let frameNumber: UInt32
    let sequenceNumber: UInt32
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
