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
        let dependencyDropCount = Locked(0)
        let sender = StreamPacketSender(
            maxPayloadSize: 512,
            sendPacket: { _, onComplete in onComplete(nil) },
            onDependencyFrameDropped: { _, _, _ in dependencyDropCount.withLock { $0 += 1 } }
        )

        await sender.start()
        let generation = sender.currentGeneration
        let expiredDeadline = CFAbsoluteTimeGetCurrent() - 1
        for frameNumber in 1 ... 2 {
            sender.enqueue(
                makeStreamPacketWorkItem(
                    payload: makeStreamPacketPayload(byteCount: 128),
                    streamID: 40,
                    frameNumber: UInt32(frameNumber),
                    sequenceNumberStart: UInt32(frameNumber * 10),
                    generation: generation,
                    sendDeadline: expiredDeadline
                )
            )
        }

        sender.enqueue(
            makeStreamPacketWorkItem(
                payload: makeStreamPacketPayload(byteCount: 128),
                streamID: 40,
                frameNumber: 3,
                sequenceNumberStart: 30,
                generation: generation,
                sendDeadline: expiredDeadline
            )
        )

        #expect(dependencyDropCount.read { $0 == 0 })
        let localSnapshot = await sender.telemetrySnapshot
        #expect(localSnapshot.senderLocalDeadlineDrops == 3)
        #expect(localSnapshot.stalePacketDrops == 3)
        await sender.stop()
    }

    @Test("Keyframe submission clears non-keyframe hold before send completion")
    func keyframeSubmissionClearsHoldBeforeCompletion() async throws {
        let submittedPackets = Locked<[StreamPacketSenderSubmittedPacket]>([])
        let pendingCompletions = Locked<[StreamPacketSenderPendingSendCompletion]>([])
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
                pendingCompletions.withLock { $0.append(StreamPacketSenderPendingSendCompletion(onComplete: onComplete)) }
            }
        )

        await sender.start()
        let generation = sender.currentGeneration
        sender.enqueue(
            makeStreamPacketWorkItem(
                payload: makeStreamPacketPayload(byteCount: 1024),
                streamID: 41,
                frameNumber: 70,
                sequenceNumberStart: 700,
                generation: generation,
                isKeyframe: true
            )
        )

        try await waitForStreamPacketSubmissionCount(submittedPackets, expectedCount: 2)

        sender.enqueue(
            makeStreamPacketWorkItem(
                payload: makeStreamPacketPayload(byteCount: 128),
                streamID: 41,
                frameNumber: 71,
                sequenceNumberStart: 800,
                generation: generation
            )
        )

        try await waitForStreamPacketSubmissionCount(submittedPackets, expectedCount: 3)

        let frameNumbers = submittedPackets.read { $0.map(\.frameNumber) }
        #expect(frameNumbers == [70, 70, 71])
        #expect(await (sender.telemetrySnapshot).nonKeyframeHoldDrops == 0)

        completePendingStreamPacketSends(pendingCompletions)
        try await waitForStreamPacketQueuedBytesToDrain(sender)
        await sender.stop()
    }

    @Test("Delayed keyframe completions do not drop following P-frames")
    func delayedKeyframeCompletionsDoNotDropFollowingPFrames() async throws {
        let submittedPackets = Locked<[StreamPacketSenderSubmittedPacket]>([])
        let pendingCompletions = Locked<[StreamPacketSenderPendingSendCompletion]>([])
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
                pendingCompletions.withLock { $0.append(StreamPacketSenderPendingSendCompletion(onComplete: onComplete)) }
            }
        )

        await sender.start()
        let generation = sender.currentGeneration
        sender.enqueue(
            makeStreamPacketWorkItem(
                payload: makeStreamPacketPayload(byteCount: 1024),
                streamID: 42,
                frameNumber: 90,
                sequenceNumberStart: 900,
                generation: generation,
                isKeyframe: true
            )
        )
        for frameNumber in 91 ... 96 {
            sender.enqueue(
                makeStreamPacketWorkItem(
                    payload: makeStreamPacketPayload(byteCount: 128),
                    streamID: 42,
                    frameNumber: UInt32(frameNumber),
                    sequenceNumberStart: UInt32(frameNumber * 10),
                    generation: generation
                )
            )
        }

        try await waitForStreamPacketSubmissionCount(submittedPackets, expectedCount: 8)

        let frameNumbers = submittedPackets.read { $0.map(\.frameNumber) }
        #expect(frameNumbers == [90, 90, 91, 92, 93, 94, 95, 96])
        #expect(await (sender.telemetrySnapshot).nonKeyframeHoldDrops == 0)

        completePendingStreamPacketSends(pendingCompletions)
        try await waitForStreamPacketQueuedBytesToDrain(sender)
        await sender.stop()
    }

}

func waitForStreamPacketSubmissionCount(
    _ submittedPackets: Locked<[StreamPacketSenderSubmittedPacket]>,
    expectedCount: Int,
    timeout: Duration = .seconds(2)
) async throws {
    try await waitForStreamPacketCondition(timeout: timeout) { submittedPackets.read { $0.count } >= expectedCount }
    #expect(submittedPackets.read { $0.count } == expectedCount)
}

func waitForStreamPacketQueuedBytesToDrain(
    _ sender: StreamPacketSender,
    timeout: Duration = .seconds(2)
) async throws {
    try await waitForStreamPacketCondition(timeout: timeout) { sender.queuedByteCount == 0 }
    #expect(sender.queuedByteCount == 0)
}

func waitForStreamPacketTelemetry(
    _ sender: StreamPacketSender,
    timeout: Duration = .seconds(2),
    until predicate: @escaping (StreamPacketSender.TelemetrySnapshot) -> Bool
) async throws -> StreamPacketSender.TelemetrySnapshot {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        let snapshot = await sender.telemetrySnapshot
        if predicate(snapshot) {
            return snapshot
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    let snapshot = await sender.telemetrySnapshot
    Issue.record("Timed out waiting for telemetry condition")
    return snapshot
}

func waitForStreamPacketCondition(
    timeout: Duration = .seconds(2),
    pollInterval: Duration = .milliseconds(10),
    _ condition: () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline {
        try await Task.sleep(for: pollInterval)
    }
}

func completePendingStreamPacketSends(_ pendingCompletions: Locked<[StreamPacketSenderPendingSendCompletion]>) {
    pendingCompletions.withLock { completions in
        completions.forEach { $0.complete(nil) }
        completions.removeAll(keepingCapacity: false)
    }
}

func makeStreamPacketPayload(byteCount: Int) -> Data {
    Data((0 ..< byteCount).map { UInt8(truncatingIfNeeded: $0) })
}

func makeStreamPacketWorkItem(
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

struct StreamPacketSenderSubmittedPacket {
    let frameNumber: UInt32
}

final class StreamPacketSenderPendingSendCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var onComplete: (@Sendable (Error?) -> Void)?

    init(onComplete: @escaping @Sendable (Error?) -> Void) {
        self.onComplete = onComplete
    }

    func complete(_ error: Error?) {
        lock.lock()
        let onComplete = onComplete
        self.onComplete = nil
        lock.unlock()
        onComplete?(error)
    }
}
#endif
