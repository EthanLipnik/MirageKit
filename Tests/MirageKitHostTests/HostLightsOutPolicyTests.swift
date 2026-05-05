//
//  HostLightsOutPolicyTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/5/26.
//

#if os(macOS)
@testable import MirageKitHost
import Testing

@Suite("Host Lights Out policy")
struct HostLightsOutPolicyTests {
    @Test("Input Monitoring is required for active Lights Out workloads")
    func inputMonitoringIsRequiredForActiveWorkloads() {
        #expect(!MirageHostService.shouldEnableLightsOut(
            hasAppStreams: true,
            hasDesktopStream: false,
            hasPendingAppStreamStart: false,
            hasPendingDesktopStreamStart: false,
            lightsOutEnabled: true,
            inputMonitoringGranted: false
        ))

        #expect(MirageHostService.shouldEnableLightsOut(
            hasAppStreams: true,
            hasDesktopStream: false,
            hasPendingAppStreamStart: false,
            hasPendingDesktopStreamStart: false,
            lightsOutEnabled: true,
            inputMonitoringGranted: true
        ))
    }

    @Test("Existing enabled preference stays inactive without Input Monitoring")
    func existingEnabledPreferenceStaysInactiveWithoutInputMonitoring() {
        #expect(!MirageHostService.shouldEnableLightsOut(
            hasAppStreams: false,
            hasDesktopStream: true,
            hasPendingAppStreamStart: false,
            hasPendingDesktopStreamStart: false,
            lightsOutEnabled: true,
            inputMonitoringGranted: false
        ))
    }

    @Test("Unified desktop workloads still activate when Input Monitoring is granted")
    func unifiedDesktopWorkloadsActivateWhenInputMonitoringIsGranted() {
        #expect(MirageHostService.shouldEnableLightsOut(
            hasAppStreams: false,
            hasDesktopStream: true,
            hasPendingAppStreamStart: false,
            hasPendingDesktopStreamStart: false,
            lightsOutEnabled: true,
            inputMonitoringGranted: true
        ))
    }
}

@Suite("Host Lights Out Escape hold")
struct HostLightsOutEscapeHoldTests {
    @Test("Event-tap holds trigger threshold once")
    func eventTapHoldsTriggerThresholdOnce() {
        let state = HostLightsOutController.EscapeHoldState()

        state.begin(source: .eventTap)

        #expect(state.checkThreshold(nanoseconds: 0))
        #expect(!state.checkThreshold(nanoseconds: 0))
    }

    @Test("Key-up style reset cancels an event-tap hold")
    func resetCancelsEventTapHold() {
        let state = HostLightsOutController.EscapeHoldState()

        state.begin(source: .eventTap)
        state.reset()

        #expect(!state.isTracking)
        #expect(state.source == nil)
    }

    @Test("Physical polling fallback can own and clear a hold")
    func physicalPollingFallbackCanOwnAndClearHold() {
        let state = HostLightsOutController.EscapeHoldState()

        state.begin(source: .physicalPoll)

        #expect(state.source == .physicalPoll)
        #expect(state.reset(ifSource: .physicalPoll))
        #expect(!state.isTracking)
    }

    @Test("Physical polling does not cancel event-tap-owned holds")
    func physicalPollingDoesNotCancelEventTapOwnedHold() {
        let state = HostLightsOutController.EscapeHoldState()

        state.begin(source: .eventTap)

        #expect(!state.reset(ifSource: .physicalPoll))
        #expect(state.isTracking)
        #expect(state.source == .eventTap)
    }
}
#endif
