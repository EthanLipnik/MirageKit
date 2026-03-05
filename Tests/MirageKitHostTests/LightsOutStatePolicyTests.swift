//
//  LightsOutStatePolicyTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/25/26.
//
//  Lights Out enablement policy for active and pending stream starts.
//

#if os(macOS)
@testable import MirageKitHost
import Testing

@Suite("Lights Out state policy")
struct LightsOutStatePolicyTests {
    @Test
    func enablesForActiveAppStreamsEvenWhenToggleIsOff() {
        #expect(
            MirageHostService.shouldEnableLightsOut(
                hasAppStreams: true,
                hasDesktopStream: false,
                hasPendingAppStreamStart: false,
                hasPendingDesktopStreamStart: false,
                lightsOutEnabled: false
            )
        )
    }

    @Test
    func enablesForPendingAppStreamSetup() {
        #expect(
            MirageHostService.shouldEnableLightsOut(
                hasAppStreams: false,
                hasDesktopStream: false,
                hasPendingAppStreamStart: true,
                hasPendingDesktopStreamStart: false,
                lightsOutEnabled: false
            )
        )
    }

    @Test
    func enablesForPendingDesktopSetupWhenToggleIsOn() {
        #expect(
            MirageHostService.shouldEnableLightsOut(
                hasAppStreams: false,
                hasDesktopStream: false,
                hasPendingAppStreamStart: false,
                hasPendingDesktopStreamStart: true,
                lightsOutEnabled: true
            )
        )
    }

    @Test
    func staysOffForPendingDesktopSetupWhenToggleIsOff() {
        #expect(
            !MirageHostService.shouldEnableLightsOut(
                hasAppStreams: false,
                hasDesktopStream: false,
                hasPendingAppStreamStart: false,
                hasPendingDesktopStreamStart: true,
                lightsOutEnabled: false
            )
        )
    }

    @Test
    func staysOffWhenNoStreamsAndNoPendingRequests() {
        #expect(
            !MirageHostService.shouldEnableLightsOut(
                hasAppStreams: false,
                hasDesktopStream: false,
                hasPendingAppStreamStart: false,
                hasPendingDesktopStreamStart: false,
                lightsOutEnabled: true
            )
        )
    }

    @Test
    func staysOffWhenEnvironmentDisablesLightsOut() {
        #expect(
            !MirageHostService.shouldEnableLightsOut(
                hasAppStreams: true,
                hasDesktopStream: true,
                hasPendingAppStreamStart: true,
                hasPendingDesktopStreamStart: true,
                lightsOutEnabled: true,
                lightsOutDisabled: true
            )
        )
    }

    @Test
    func resolvesEnvironmentDisableFlag() {
        #expect(
            MirageHostService.isLightsOutDisabledByEnvironment(
                environment: [MirageHostService.lightsOutDisableEnvironmentKey: "1"]
            )
        )
        #expect(
            !MirageHostService.isLightsOutDisabledByEnvironment(
                environment: [MirageHostService.lightsOutDisableEnvironmentKey: "0"]
            )
        )
        #expect(
            !MirageHostService.isLightsOutDisabledByEnvironment(
                environment: [:]
            )
        )
    }

    @Test
    func locksHostWhenStreamingBecomesIdle() {
        #expect(
            MirageHostService.shouldLockHostWhenStreamingStops(
                lockHostWhenStreamingStops: true,
                sessionState: .active,
                hasAppStreams: false,
                hasDesktopStream: false,
                hasPendingAppStreamStart: false,
                hasPendingDesktopStreamStart: false
            )
        )
    }

    @Test
    func doesNotLockHostWhileStillStreaming() {
        #expect(
            !MirageHostService.shouldLockHostWhenStreamingStops(
                lockHostWhenStreamingStops: true,
                sessionState: .active,
                hasAppStreams: true,
                hasDesktopStream: false,
                hasPendingAppStreamStart: false,
                hasPendingDesktopStreamStart: false
            )
        )
    }

    @Test
    func doesNotLockHostDuringPendingStreamTransition() {
        #expect(
            !MirageHostService.shouldLockHostWhenStreamingStops(
                lockHostWhenStreamingStops: true,
                sessionState: .active,
                hasAppStreams: false,
                hasDesktopStream: false,
                hasPendingAppStreamStart: true,
                hasPendingDesktopStreamStart: false
            )
        )
    }

    @Test
    func doesNotLockHostWhenSettingIsDisabled() {
        #expect(
            !MirageHostService.shouldLockHostWhenStreamingStops(
                lockHostWhenStreamingStops: false,
                sessionState: .active,
                hasAppStreams: false,
                hasDesktopStream: false,
                hasPendingAppStreamStart: false,
                hasPendingDesktopStreamStart: false
            )
        )
    }
}
#endif
