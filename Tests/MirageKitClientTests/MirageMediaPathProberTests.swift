//
//  MirageMediaPathProberTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/15/26.
//

@testable import MirageKitClient
import Network
import Testing

@Suite("MirageMediaPathProber")
struct MirageMediaPathProberTests {
    @Test("Picks lowest RTT candidate")
    func picksLowestRTTCandidate() {
        let results = [
            MediaPathProbeResult(
                interfaceLabel: "wifi",
                rttMs: 5.0,
                includePeerToPeer: false,
                interfaceType: .wifi
            ),
            MediaPathProbeResult(
                interfaceLabel: "wired",
                rttMs: 1.2,
                includePeerToPeer: false,
                interfaceType: .wiredEthernet
            ),
            MediaPathProbeResult(
                interfaceLabel: "p2p",
                rttMs: 3.5,
                includePeerToPeer: true,
                interfaceType: nil
            ),
        ]

        let best = MediaPathProbeResult.bestCandidate(from: results)
        #expect(best != nil)
        #expect(best?.interfaceLabel == "wired")
        #expect(best?.rttMs == 1.2)
    }

    @Test("Returns nil for empty results")
    func returnsNilForEmptyResults() {
        let best = MediaPathProbeResult.bestCandidate(from: [])
        #expect(best == nil)
    }

    @Test("Hysteresis prevents migration when improvement < 30%")
    func hysteresisPreventsSmallImprovement() {
        let current = MediaPathProbeResult(
            interfaceLabel: "wifi",
            rttMs: 2.0,
            includePeerToPeer: false,
            interfaceType: .wifi
        )
        let candidate = MediaPathProbeResult(
            interfaceLabel: "wired",
            rttMs: 1.5,
            includePeerToPeer: false,
            interfaceType: .wiredEthernet
        )

        // 25% improvement — below the 30% threshold
        #expect(!MediaPathProbeResult.shouldMigrate(from: current, to: candidate))
    }

    @Test("Hysteresis allows migration when improvement >= 30%")
    func hysteresisAllowsLargeImprovement() {
        let current = MediaPathProbeResult(
            interfaceLabel: "wifi",
            rttMs: 5.0,
            includePeerToPeer: false,
            interfaceType: .wifi
        )
        let candidate = MediaPathProbeResult(
            interfaceLabel: "wired",
            rttMs: 1.0,
            includePeerToPeer: false,
            interfaceType: .wiredEthernet
        )

        // 80% improvement — well above the 30% threshold
        #expect(MediaPathProbeResult.shouldMigrate(from: current, to: candidate))
    }
}
