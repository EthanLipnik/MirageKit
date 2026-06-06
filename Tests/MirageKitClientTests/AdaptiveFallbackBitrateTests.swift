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
import MirageCore

@Suite("Adaptive Recovery Mode")
struct AdaptiveFallbackBitrateTests {
    @Test("Clearing decoder compatibility state removes stored baseline")
    @MainActor
    func clearingDecoderCompatibilityStateRemovesStoredBaseline() {
        let service = MirageClientService(deviceName: "Unit Test")
        let streamID: StreamID = 44
        service.configureDecoderColorDepthBaseline(for: streamID, colorDepth: .ultra)

        service.clearDecoderColorDepthState(for: streamID)

        #expect(service.decoderCompatibilityCurrentColorDepthByStream[streamID] == nil)
        #expect(service.decoderCompatibilityBaselineColorDepthByStream[streamID] == nil)
    }
}
#endif
