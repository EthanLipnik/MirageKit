//
//  AdaptiveFallbackBitrateTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/9/26.
//
//  Coverage for bitrate-step adaptive fallback behavior.
//

@testable import MirageKitClient
import Foundation
import Testing

#if os(macOS)
@Suite("Adaptive Fallback Bitrate")
struct AdaptiveFallbackBitrateTests {
    @Test("Bitrate step reduces by fifteen percent")
    func bitrateStepReduction() {
        let next = MirageClientService.nextAdaptiveFallbackBitrate(
            currentBitrate: 20_000_000,
            step: 0.85,
            floor: 8_000_000
        )

        #expect(next == 17_000_000)
    }

    @Test("Bitrate step clamps at floor")
    func bitrateFloorClamp() {
        let next = MirageClientService.nextAdaptiveFallbackBitrate(
            currentBitrate: 8_500_000,
            step: 0.85,
            floor: 8_000_000
        )

        #expect(next == 8_000_000)
    }

    @Test("Bitrate step stops at floor")
    func bitrateStepStopsAtFloor() {
        let next = MirageClientService.nextAdaptiveFallbackBitrate(
            currentBitrate: 8_000_000,
            step: 0.85,
            floor: 8_000_000
        )

        #expect(next == nil)
    }

    @Test("Disabled adaptive fallback does not apply a bitrate step")
    @MainActor
    func disabledAdaptiveFallbackSkipsUpdates() async throws {
        let service = MirageClientService(deviceName: "Unit Test")
        let streamID: StreamID = 42
        service.adaptiveFallbackEnabled = false
        service.adaptiveFallbackBitrateByStream[streamID] = 20_000_000
        service.adaptiveFallbackLastAppliedTime[streamID] = 0

        service.handleAdaptiveFallbackTrigger(for: streamID)
        try await Task.sleep(for: .milliseconds(50))

        #expect(service.adaptiveFallbackBitrateByStream[streamID] == 20_000_000)
        #expect(service.adaptiveFallbackLastAppliedTime[streamID] == 0)
    }

    @Test("Signal-only adaptive fallback policy does not mutate encoder settings")
    @MainActor
    func signalOnlyPolicySkipsMutation() async throws {
        let service = MirageClientService(deviceName: "Unit Test")
        let streamID: StreamID = 43
        service.adaptiveFallbackEnabled = true
        service.adaptiveFallbackMode = .automatic
        service.adaptiveFallbackBitrateByStream[streamID] = 20_000_000
        service.adaptiveFallbackBitDepthByStream[streamID] = .tenBit
        service.adaptiveFallbackLastAppliedTime[streamID] = 0

        service.handleAdaptiveFallbackTrigger(for: streamID)
        try await Task.sleep(for: .milliseconds(50))

        #expect(service.adaptiveFallbackBitrateByStream[streamID] == 20_000_000)
        #expect(service.adaptiveFallbackBitDepthByStream[streamID] == .tenBit)
        #expect(service.adaptiveFallbackLastAppliedTime[streamID] == 0)
    }
}
#endif
