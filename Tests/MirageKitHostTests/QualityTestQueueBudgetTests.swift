//
//  QualityTestQueueBudgetTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/1/26.
//
//  Quality-test queue sizing for high-throughput local links.
//

@testable import MirageKitHost
import MirageConnectivity
import MirageMedia
import Testing

#if os(macOS)
@Suite("Quality Test Queue Budget")
struct QualityTestQueueBudgetTests {
    @Test("Quality test queue no longer stops at the interactive-media packet window")
    func queueWindowExceedsInteractiveMediaPacketCap() {
        let packetBytes = 1_338
        let interactiveLimits = MirageMedia.MirageMediaSendProfile.interactiveMedia.queuedUnreliableRecommendedLimits

        #expect(
            MirageHostService.qualityTestCanEnqueuePacket(
                outstandingPackets: interactiveLimits.maxOutstandingPackets,
                outstandingBytes: interactiveLimits.maxOutstandingPackets * packetBytes,
                packetBytes: packetBytes
            )
        )
    }

    @Test("Quality test queue still enforces the packet cap")
    func queueWindowRespectsPacketCap() {
        let packetBytes = 1_338
        let limits = MirageMedia.MirageMediaSendProfile.throughputProbe.queuedUnreliableRecommendedLimits

        #expect(
            !MirageHostService.qualityTestCanEnqueuePacket(
                outstandingPackets: limits.maxOutstandingPackets,
                outstandingBytes: limits.maxOutstandingPackets * packetBytes,
                packetBytes: packetBytes
            )
        )
    }

    @Test("Streaming replay queue respects the interactive packet cap")
    func streamingReplayQueueRespectsInteractivePacketCap() {
        let packetBytes = 1_338
        let limits = MirageMedia.MirageMediaSendProfile.interactiveMedia.queuedUnreliableRecommendedLimits

        #expect(
            !MirageHostService.qualityTestCanEnqueuePacket(
                outstandingPackets: limits.maxOutstandingPackets,
                outstandingBytes: limits.maxOutstandingPackets * packetBytes,
                packetBytes: packetBytes,
                profile: .interactiveMedia
            )
        )
    }

    @Test("Quality test queue enforces the byte cap once packets are in flight")
    func queueWindowRespectsByteCap() {
        let limits = MirageMedia.MirageMediaSendProfile.throughputProbe.queuedUnreliableRecommendedLimits
        #expect(
            !MirageHostService.qualityTestCanEnqueuePacket(
                outstandingPackets: 1,
                outstandingBytes: limits.maxOutstandingBytes - 100,
                packetBytes: 200
            )
        )
    }

    @Test("Delivery-window miss fires when the fixed measurement window underdelivers")
    func deliveryWindowMissTriggersOnMeasurementUnderdelivery() {
        #expect(
            MirageHostService.qualityTestMissedDeliveryWindow(
                targetBitrateBps: 1_024_000_000,
                measurementDurationMs: 1_500,
                payloadBytes: 1_322,
                packetBytes: 1_338,
                sentPayloadBytes: 105_302_588,
                encounteredEnqueueBackpressure: false,
                outstandingPacketsAfterSettle: 0
            )
        )
    }
}
#endif
