//
//  AdaptiveFallbackBitrateTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/9/26.
//

#if os(macOS)
@testable import MirageKitClient
import Foundation
import Testing

@Suite("Adaptive Recovery Mode")
struct AdaptiveFallbackBitrateTests {

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
