//
//  LightsOutStatePolicyTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/25/26.
//
//  Lights Out enablement policy for active and pending stream starts.
//

#if os(macOS)
import Loom
@testable import MirageKitHost
import Testing

@Suite("Lights Out state policy")
struct LightsOutStatePolicyTests {
    @Test
    func enablesForActiveAppStreamsWhenToggleIsOn() {
        #expect(
            MirageHostService.shouldEnableLightsOut(
                hasAppStreams: true,
                hasDesktopStream: false,
                hasPendingAppStreamStart: false,
                hasPendingDesktopStreamStart: false,
                desktopStreamMode: .unified,
                lightsOutEnabled: true
            )
        )
    }

    @Test
    func staysOffForActiveAppStreamsWhenToggleIsOff() {
        #expect(
            !MirageHostService.shouldEnableLightsOut(
                hasAppStreams: true,
                hasDesktopStream: false,
                hasPendingAppStreamStart: false,
                hasPendingDesktopStreamStart: false,
                desktopStreamMode: .unified,
                lightsOutEnabled: false
            )
        )
    }

    @Test
    func enablesForPendingAppStreamSetupWhenToggleIsOn() {
        #expect(
            MirageHostService.shouldEnableLightsOut(
                hasAppStreams: false,
                hasDesktopStream: false,
                hasPendingAppStreamStart: true,
                hasPendingDesktopStreamStart: false,
                desktopStreamMode: .unified,
                lightsOutEnabled: true
            )
        )
    }

    @Test
    func staysOffForPendingAppStreamSetupWhenToggleIsOff() {
        #expect(
            !MirageHostService.shouldEnableLightsOut(
                hasAppStreams: false,
                hasDesktopStream: false,
                hasPendingAppStreamStart: true,
                hasPendingDesktopStreamStart: false,
                desktopStreamMode: .unified,
                lightsOutEnabled: false
            )
        )
    }

    @Test
    func enablesForActiveDesktopStreamWhenToggleIsOn() {
        #expect(
            MirageHostService.shouldEnableLightsOut(
                hasAppStreams: false,
                hasDesktopStream: true,
                hasPendingAppStreamStart: false,
                hasPendingDesktopStreamStart: false,
                desktopStreamMode: .unified,
                lightsOutEnabled: true
            )
        )
    }

    @Test
    func staysOffForActiveDesktopStreamWhenToggleIsOff() {
        #expect(
            !MirageHostService.shouldEnableLightsOut(
                hasAppStreams: false,
                hasDesktopStream: true,
                hasPendingAppStreamStart: false,
                hasPendingDesktopStreamStart: false,
                desktopStreamMode: .unified,
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
                desktopStreamMode: .unified,
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
                desktopStreamMode: .unified,
                lightsOutEnabled: false
            )
        )
    }

    @Test
    func staysOffForActiveSecondaryDesktopStreamEvenWhenToggleIsOn() {
        #expect(
            !MirageHostService.shouldEnableLightsOut(
                hasAppStreams: false,
                hasDesktopStream: true,
                hasPendingAppStreamStart: false,
                hasPendingDesktopStreamStart: false,
                desktopStreamMode: .secondary,
                lightsOutEnabled: true
            )
        )
    }

    @Test
    func staysOffForPendingSecondaryDesktopSetupEvenWhenToggleIsOn() {
        #expect(
            !MirageHostService.shouldEnableLightsOut(
                hasAppStreams: false,
                hasDesktopStream: false,
                hasPendingAppStreamStart: false,
                hasPendingDesktopStreamStart: true,
                desktopStreamMode: .secondary,
                lightsOutEnabled: true
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
                desktopStreamMode: .unified,
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
                desktopStreamMode: .unified,
                lightsOutEnabled: true,
                lightsOutDisabledByEnvironment: true
            )
        )
    }

    @Test
    func allowsLightsOutWhileSessionIsLocked() {
        #expect(MirageHostService.shouldAllowLightsOut(for: .credentialsRequired))
    }

    @Test
    func allowsLightsOutAtLoginWindow() {
        #expect(MirageHostService.shouldAllowLightsOut(for: .credentialsAndUserIdentifierRequired))
    }

    @Test
    func disablesLightsOutWhenSessionIsUnavailable() {
        #expect(!MirageHostService.shouldAllowLightsOut(for: .unavailable))
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

    @Test
    func doesNotLockHostForDisconnectDrivenIdleTransition() {
        #expect(
            !MirageHostService.shouldLockHostWhenStreamingStops(
                lockHostWhenStreamingStops: true,
                sessionState: .ready,
                hasAppStreams: false,
                hasDesktopStream: false,
                hasPendingAppStreamStart: false,
                hasPendingDesktopStreamStart: false,
                triggeredByExplicitStreamStop: false
            )
        )
    }
}
#endif
