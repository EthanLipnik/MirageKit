//
//  AdaptiveFallbackBitrateTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/9/26.
//

@testable import MirageKitClient
import Foundation
import Testing

#if os(macOS)
@Suite("Adaptive Recovery Mode")
struct AdaptiveFallbackBitrateTests {
    @Test("Disabled mode applies decoder compatibility fallback for ten-bit streams")
    func disabledModeAppliesDecoderCompatibilityFallbackForTenBitStreams() {
        #expect(
            MirageClientService.shouldApplyDecoderCompatibilityFallback(
                mode: .disabled,
                resolvedBitDepth: .tenBit,
                lastAppliedTime: nil,
                now: 20,
                cooldown: 15
            )
        )
        #expect(
            MirageClientService.shouldApplyDecoderCompatibilityFallback(
                mode: .disabled,
                resolvedBitDepth: .eightBit,
                lastAppliedTime: nil,
                now: 20,
                cooldown: 15
            ) == false
        )
    }

    @Test("Adaptive mode never applies decoder compatibility fallback")
    func adaptiveModeNeverAppliesDecoderCompatibilityFallback() {
        #expect(
            MirageClientService.shouldApplyDecoderCompatibilityFallback(
                mode: .adaptive,
                resolvedBitDepth: .tenBit,
                lastAppliedTime: nil,
                now: 20,
                cooldown: 15
            ) == false
        )
        #expect(
            MirageClientService.shouldApplyDecoderCompatibilityFallback(
                mode: .adaptive,
                resolvedBitDepth: .eightBit,
                lastAppliedTime: 10,
                now: 40,
                cooldown: 15
            ) == false
        )
    }

    @Test("Decoder compatibility fallback respects cooldown")
    func decoderCompatibilityFallbackRespectsCooldown() {
        #expect(
            MirageClientService.shouldApplyDecoderCompatibilityFallback(
                mode: .disabled,
                resolvedBitDepth: .tenBit,
                lastAppliedTime: 10,
                now: 20,
                cooldown: 15
            ) == false
        )
        #expect(
            MirageClientService.shouldApplyDecoderCompatibilityFallback(
                mode: .disabled,
                resolvedBitDepth: .tenBit,
                lastAppliedTime: 10,
                now: 26,
                cooldown: 15
            )
        )
    }

    @Test("Adaptive mode leaves decoder compatibility state unchanged")
    @MainActor
    func adaptiveModeLeavesDecoderCompatibilityStateUnchanged() async throws {
        let service = MirageClientService(deviceName: "Unit Test")
        let streamID: StreamID = 43
        service.adaptiveFallbackMode = .adaptive
        service.configureDecoderColorDepthBaseline(for: streamID, colorDepth: .pro)

        service.handleAdaptiveFallbackTrigger(for: streamID)
        try await Task.sleep(for: .milliseconds(50))

        #expect(service.decoderCompatibilityCurrentColorDepthByStream[streamID] == .pro)
        #expect(service.decoderCompatibilityBaselineColorDepthByStream[streamID] == .pro)
        #expect(service.decoderCompatibilityFallbackLastAppliedTime[streamID] == 0)
    }

    @Test("Clearing decoder compatibility state removes stored baseline")
    @MainActor
    func clearingDecoderCompatibilityStateRemovesStoredBaseline() {
        let service = MirageClientService(deviceName: "Unit Test")
        let streamID: StreamID = 44
        service.configureDecoderColorDepthBaseline(for: streamID, colorDepth: .ultra)

        service.clearDecoderColorDepthState(for: streamID)

        #expect(service.decoderCompatibilityCurrentColorDepthByStream[streamID] == nil)
        #expect(service.decoderCompatibilityBaselineColorDepthByStream[streamID] == nil)
        #expect(service.decoderCompatibilityFallbackLastAppliedTime[streamID] == nil)
    }
}
#endif
