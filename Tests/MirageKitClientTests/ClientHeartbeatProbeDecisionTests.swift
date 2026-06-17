//
//  ClientHeartbeatProbeDecisionTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/9/26.
//

@testable import MirageKitClient
import Testing

@Suite("Client Heartbeat Probe Decision")
struct ClientHeartbeatProbeDecisionTests {
    @Test("Idle connection probes after inactivity threshold")
    func idleConnectionProbesAfterInactivityThreshold() {
        #expect(
            clientHeartbeatProbeDecision(
                inactivityDuration: 10.1,
                inactivityThreshold: 10.0,
                hasActiveStreams: false,
                hasPendingStreamSetup: false,
                isWithinGracePeriod: false,
                hasInFlightPingOrHostOperation: false
            ) == .sendPing
        )
    }

    @Test("Recent inbound activity suppresses probes")
    func recentInboundActivitySuppressesProbe() {
        #expect(
            clientHeartbeatProbeDecision(
                inactivityDuration: 4.9,
                inactivityThreshold: 10.0,
                hasActiveStreams: false,
                hasPendingStreamSetup: false,
                isWithinGracePeriod: false,
                hasInFlightPingOrHostOperation: false
            ) == .waitForInboundActivity
        )
    }

    @Test("Active streams suppress probes")
    func activeStreamsSuppressProbe() {
        #expect(
            clientHeartbeatProbeDecision(
                inactivityDuration: 30,
                inactivityThreshold: 10.0,
                hasActiveStreams: true,
                hasPendingStreamSetup: false,
                isWithinGracePeriod: false,
                hasInFlightPingOrHostOperation: false
            ) == .skipActiveStream
        )
    }

    @Test("Grace periods suppress probes")
    func gracePeriodsSuppressProbe() {
        #expect(
            clientHeartbeatProbeDecision(
                inactivityDuration: 30,
                inactivityThreshold: 10.0,
                hasActiveStreams: false,
                hasPendingStreamSetup: false,
                isWithinGracePeriod: true,
                hasInFlightPingOrHostOperation: false
            ) == .skipGracePeriod
        )
    }

    @Test("In-flight ping or host operation suppresses probes")
    func inFlightOperationsSuppressProbe() {
        #expect(
            clientHeartbeatProbeDecision(
                inactivityDuration: 30,
                inactivityThreshold: 10.0,
                hasActiveStreams: false,
                hasPendingStreamSetup: false,
                isWithinGracePeriod: false,
                hasInFlightPingOrHostOperation: true
            ) == .skipOperationInFlight
        )
    }

    @Test("Pending stream setup suppresses heartbeat probes")
    func pendingStreamSetupSuppressesProbe() {
        #expect(
            clientHeartbeatProbeDecision(
                inactivityDuration: 30,
                inactivityThreshold: 10.0,
                hasActiveStreams: false,
                hasPendingStreamSetup: true,
                isWithinGracePeriod: false,
                hasInFlightPingOrHostOperation: false
            ) == .skipOperationInFlight
        )
    }
}
