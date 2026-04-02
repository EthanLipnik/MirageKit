//
//  QualityTestQueueBudgetTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/1/26.
//
//  Quality-test queue sizing for high-throughput local links.
//

@testable import MirageKitHost
import Loom
import Testing

#if os(macOS)
@Suite("Quality Test Queue Budget")
struct QualityTestQueueBudgetTests {
    @Test("Quality test queue no longer stops at the interactive-media packet window")
    func queueWindowExceedsInteractiveMediaPacketCap() {
        let packetBytes = 1_338
        let interactiveLimits = LoomQueuedUnreliableSendProfile.interactiveMedia.recommendedLimits

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
        let limits = LoomQueuedUnreliableSendProfile.throughputProbe.recommendedLimits

        #expect(
            !MirageHostService.qualityTestCanEnqueuePacket(
                outstandingPackets: limits.maxOutstandingPackets,
                outstandingBytes: limits.maxOutstandingPackets * packetBytes,
                packetBytes: packetBytes
            )
        )
    }

    @Test("Quality test queue enforces the byte cap once packets are in flight")
    func queueWindowRespectsByteCap() {
        let limits = LoomQueuedUnreliableSendProfile.throughputProbe.recommendedLimits
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

    @Test("Connection-limit sweep stops only when first-breach mode sees an overload")
    func firstBreachModeStopsAfterOverload() {
        #expect(
            MirageHostService.qualityTestShouldTerminateSweep(
                stopAfterFirstBreach: true,
                deliveryWindowMissed: true
            )
        )
        #expect(
            !MirageHostService.qualityTestShouldTerminateSweep(
                stopAfterFirstBreach: false,
                deliveryWindowMissed: true
            )
        )
        #expect(
            !MirageHostService.qualityTestShouldTerminateSweep(
                stopAfterFirstBreach: true,
                deliveryWindowMissed: false
            )
        )
    }
}
#endif
