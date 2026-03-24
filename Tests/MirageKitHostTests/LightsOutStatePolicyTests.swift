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
        // In DEBUG builds, app streaming does not force lights out so the
        // developer can still see and interact with the host display.
        #if DEBUG
        #expect(
            !MirageHostService.shouldEnableLightsOut(
                hasAppStreams: true,
                hasDesktopStream: false,
                hasPendingAppStreamStart: false,
                hasPendingDesktopStreamStart: false,
                lightsOutEnabled: false
            )
        )
        #else
        #expect(
            MirageHostService.shouldEnableLightsOut(
                hasAppStreams: true,
                hasDesktopStream: false,
                hasPendingAppStreamStart: false,
                hasPendingDesktopStreamStart: false,
                lightsOutEnabled: false
            )
        )
        #endif
    }

    @Test
    func enablesForPendingAppStreamSetup() {
        #if DEBUG
        #expect(
            !MirageHostService.shouldEnableLightsOut(
                hasAppStreams: false,
                hasDesktopStream: false,
                hasPendingAppStreamStart: true,
                hasPendingDesktopStreamStart: false,
                lightsOutEnabled: false
            )
        )
        #else
        #expect(
            MirageHostService.shouldEnableLightsOut(
                hasAppStreams: false,
                hasDesktopStream: false,
                hasPendingAppStreamStart: true,
                hasPendingDesktopStreamStart: false,
                lightsOutEnabled: false
            )
        )
        #endif
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
                lightsOutDisabledByEnvironment: true
            )
        )
    }

    @Test
    func secondaryDisplaySuppressesLightsOutForDesktopStream() {
        // Secondary display mode overrides lightsOutEnabled to false,
        // so desktop streams in secondary mode never trigger Lights Out.
        #expect(
            !MirageHostService.shouldEnableLightsOut(
                hasAppStreams: false,
                hasDesktopStream: true,
                hasPendingAppStreamStart: false,
                hasPendingDesktopStreamStart: false,
                lightsOutEnabled: false
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
                sessionState: .ready,
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
                sessionState: .ready,
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
                sessionState: .ready,
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
                sessionState: .ready,
                hasAppStreams: false,
                hasDesktopStream: false,
                hasPendingAppStreamStart: false,
                hasPendingDesktopStreamStart: false
            )
        )
    }
}
#endif
