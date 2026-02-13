//
//  LatencyModeDefaultsTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/13/26.
//
//  Coverage for client latency mode defaults.
//

import MirageKit
import MirageKitClient
import Testing

@Suite("Client Latency Mode Defaults")
struct LatencyModeDefaultsTests {
    @MainActor
    @Test("Client service defaults to auto latency mode")
    func clientServiceDefaultsToAutoLatency() {
        let service = MirageClientService()
        #expect(service.latencyMode == .auto)
    }
}
