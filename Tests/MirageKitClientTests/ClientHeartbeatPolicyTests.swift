//
//  ClientHeartbeatPolicyTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/9/26.
//

@testable import MirageKitClient
import Testing

@Suite("Client Heartbeat Policy")
struct ClientHeartbeatPolicyTests {
    @Test("Idle connection probes after inactivity threshold")
    func idleConnectionProbesAfterInactivityThreshold() {
        #expect(
            clientHeartbeatProbeDecision(
                inactivityDuration: 10.1,
                inactivityThreshold: 10.0,
                hasActiveStreams: false,
                isWithinGracePeriod: false,
                qualityTestActive: false,
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
                isWithinGracePeriod: false,
                qualityTestActive: false,
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
                isWithinGracePeriod: false,
                qualityTestActive: false,
                hasInFlightPingOrHostOperation: false
            ) == .skipActiveStream
        )
    }

    @Test("Grace periods and quality tests suppress probes")
    func gracePeriodsAndQualityTestsSuppressProbe() {
        #expect(
            clientHeartbeatProbeDecision(
                inactivityDuration: 30,
                inactivityThreshold: 10.0,
                hasActiveStreams: false,
                isWithinGracePeriod: true,
                qualityTestActive: false,
                hasInFlightPingOrHostOperation: false
            ) == .skipGracePeriod
        )
        #expect(
            clientHeartbeatProbeDecision(
                inactivityDuration: 30,
                inactivityThreshold: 10.0,
                hasActiveStreams: false,
                isWithinGracePeriod: false,
                qualityTestActive: true,
                hasInFlightPingOrHostOperation: false
            ) == .skipQualityTest
        )
    }

    @Test("In-flight ping or host operation suppresses probes")
    func inFlightOperationsSuppressProbe() {
        #expect(
            clientHeartbeatProbeDecision(
                inactivityDuration: 30,
                inactivityThreshold: 10.0,
                hasActiveStreams: false,
                isWithinGracePeriod: false,
                qualityTestActive: false,
                hasInFlightPingOrHostOperation: true
            ) == .skipOperationInFlight
        )
    }

    @Test("Host support log export counts as an in-flight host operation")
    func hostSupportLogExportCountsAsHostOperation() {
        #expect(
            clientHeartbeatHasInFlightHostOperation(
                hostWallpaperRequestInFlight: false,
                hostSupportLogExportInFlight: true
            )
        )
    }

    @Test("No host operation is reported when wallpaper and host log exports are idle")
    func idleHostOperationsReportFalse() {
        #expect(
            !clientHeartbeatHasInFlightHostOperation(
                hostWallpaperRequestInFlight: false,
                hostSupportLogExportInFlight: false
            )
        )
    }
}
