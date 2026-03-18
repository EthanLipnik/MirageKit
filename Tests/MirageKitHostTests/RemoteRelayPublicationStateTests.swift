//
//  RemoteRelayPublicationStateTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/12/26.
//
//  Sticky remote signaling candidate publication policy tests.
//

@_spi(HostApp) @testable import MirageKitHost
import Testing

#if os(macOS)
import MirageKit

@Suite("Remote Relay Publication State")
struct RemoteRelayPublicationStateTests {
    @Test("Cold start defers while listener is not ready")
    func coldStartDefersWithoutPublishingEmptyCandidates() {
        let state = MirageRemoteRelayPublicationState()

        let decision = state.decision(
            listenerReady: false,
            freshCandidates: []
        )

        #expect(decision == .`defer`(reason: .listenerNotReady))
    }

    @Test("Listener-ready STUN failures defer until first candidates exist")
    func listenerReadyDefersWhenProbeFailsWithoutStickyCandidates() {
        let state = MirageRemoteRelayPublicationState()

        let decision = state.decision(
            listenerReady: true,
            freshCandidates: []
        )

        #expect(decision == .`defer`(reason: .stunProbeFailed))
    }

    @Test("Fresh publish becomes sticky for later STUN failures")
    func freshPublishBecomesSticky() {
        var state = MirageRemoteRelayPublicationState()
        let candidates = [
            LoomRemoteCandidate(
                transport: .quic,
                address: "203.0.113.10",
                port: 4433
            )
        ]

        let initialDecision = state.decision(
            listenerReady: true,
            freshCandidates: candidates
        )
        #expect(initialDecision == .publish(candidates: candidates, source: .fresh))

        state.recordPublishedCandidates(candidates)

        let stickyDecision = state.decision(
            listenerReady: true,
            freshCandidates: []
        )
        #expect(stickyDecision == .publish(candidates: candidates, source: .sticky(reason: .stunProbeFailed)))
    }

    @Test("Sticky candidates survive transient listener unavailability")
    func stickyCandidatesSurviveListenerUnavailable() {
        var state = MirageRemoteRelayPublicationState()
        let candidates = [
            LoomRemoteCandidate(
                transport: .quic,
                address: "198.51.100.20",
                port: 7443
            )
        ]
        state.recordPublishedCandidates(candidates)

        let decision = state.decision(
            listenerReady: false,
            freshCandidates: []
        )

        #expect(decision == .publish(candidates: candidates, source: .sticky(reason: .listenerNotReady)))
    }

    @Test("Reset clears sticky publication state")
    func resetClearsStickyPublicationState() {
        var state = MirageRemoteRelayPublicationState()
        let candidates = [
            LoomRemoteCandidate(
                transport: .quic,
                address: "192.0.2.44",
                port: 9443
            )
        ]
        state.recordPublishedCandidates(candidates)

        state.reset()

        let decision = state.decision(
            listenerReady: true,
            freshCandidates: []
        )

        #expect(decision == .`defer`(reason: .stunProbeFailed))
    }

    @Test("Multiple candidates are published together")
    func multipleCandidatesPublishedTogether() {
        var state = MirageRemoteRelayPublicationState()
        let candidates = [
            LoomRemoteCandidate(transport: .quic, address: "203.0.113.10", port: 4433),
            LoomRemoteCandidate(transport: .tcp, address: "203.0.113.10", port: 8443),
        ]

        let decision = state.decision(
            listenerReady: true,
            freshCandidates: candidates
        )
        #expect(decision == .publish(candidates: candidates, source: .fresh))

        state.recordPublishedCandidates(candidates)

        let stickyDecision = state.decision(
            listenerReady: true,
            freshCandidates: []
        )
        #expect(stickyDecision == .publish(candidates: candidates, source: .sticky(reason: .stunProbeFailed)))
    }
}
#endif
