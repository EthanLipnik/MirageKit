//
//  StreamPacketSenderTelemetryTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

#if os(macOS)
@testable import MirageKitHost
import CoreFoundation
import MirageKit
import Testing

@Suite("Stream Packet Sender Telemetry")
struct StreamPacketSenderTelemetryTests {
    @Test("Consumed telemetry windows clear send delay aggregates")
    func consumedTelemetryWindowsClearSendDelayAggregates() async throws {
        let sender = StreamPacketSender(
            maxPayloadSize: 512,
            sendPacketWithMetadata: { _, _, onComplete in
                onComplete(nil)
            }
        )

        await sender.start()
        let generation = sender.currentGeneration
        sender.enqueue(
            makeStreamPacketWorkItem(
                payload: makeStreamPacketPayload(byteCount: 256),
                streamID: 43,
                frameNumber: 101,
                sequenceNumberStart: 1010,
                generation: generation,
                encodedAt: CFAbsoluteTimeGetCurrent() - 0.02
            )
        )

        _ = try await waitForStreamPacketTelemetry(
            sender,
            timeout: .seconds(2)
        ) { snapshot in
            snapshot.sendStartDelayAverageMs > 0 &&
                snapshot.sendCompletionAverageMs > 0 &&
                snapshot.nonKeyframeSendStartDelayMaxMs > 0 &&
                snapshot.nonKeyframeSendCompletionMaxMs > 0
        }

        let firstWindow = await sender.consumeTelemetrySnapshot()
        #expect(firstWindow.sendStartDelayAverageMs > 0)
        #expect(firstWindow.sendCompletionAverageMs > 0)
        #expect(firstWindow.nonKeyframeSendStartDelayMaxMs > 0)
        #expect(firstWindow.nonKeyframeSendCompletionMaxMs > 0)

        let secondWindow = await sender.consumeTelemetrySnapshot()
        #expect(secondWindow.sendStartDelayAverageMs == 0)
        #expect(secondWindow.sendCompletionAverageMs == 0)
        #expect(secondWindow.nonKeyframeSendStartDelayMaxMs == 0)
        #expect(secondWindow.nonKeyframeSendCompletionMaxMs == 0)

        await sender.stop()
    }

    @Test("Consumed telemetry windows clear transient generation-abort drops")
    func consumedTelemetryWindowsClearTransientGenerationAbortDrops() async throws {
        let sender = StreamPacketSender(
            maxPayloadSize: 512,
            sendPacketWithMetadata: { _, _, onComplete in
                onComplete(nil)
            }
        )

        await sender.start()
        let generation = sender.currentGeneration
        sender.enqueue(
            makeStreamPacketWorkItem(
                payload: makeStreamPacketPayload(byteCount: 128),
                streamID: 44,
                frameNumber: 201,
                sequenceNumberStart: 2010,
                generation: generation &+ 1
            )
        )

        _ = try await waitForStreamPacketTelemetry(
            sender,
            timeout: .seconds(2)
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
            sendPacketWithMetadata: { _, _, onComplete in
                onComplete(nil)
            }
        )

        await sender.start()
        let generation = sender.currentGeneration
        sender.enqueue(
            makeStreamPacketWorkItem(
                payload: makeStreamPacketPayload(byteCount: 1024),
                streamID: 45,
                frameNumber: 301,
                sequenceNumberStart: 3010,
                generation: generation,
                isKeyframe: true,
                encodedAt: CFAbsoluteTimeGetCurrent() - 0.02
            )
        )

        let snapshot = try await waitForStreamPacketTelemetry(
            sender,
            timeout: .seconds(2)
        ) { snapshot in
            snapshot.sendCompletionAverageMs > 0
        }

        #expect(snapshot.sendStartDelayAverageMs > 0)
        #expect(snapshot.sendCompletionAverageMs > 0)
        #expect(snapshot.nonKeyframeSendStartDelayMaxMs == 0)
        #expect(snapshot.nonKeyframeSendCompletionMaxMs == 0)

        await sender.stop()
    }
}
#endif
