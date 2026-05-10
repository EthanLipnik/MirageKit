//
//  MirageStreamForegroundRecoveryPolicyTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/6/26.
//

import Foundation
@testable import MirageKitClient
import Testing

@Suite("Stream foreground recovery policy")
struct MirageStreamForegroundRecoveryPolicyTests {
    @Test("UIKit-confirmed activation dispatches while SwiftUI scene phase is inactive")
    func inputCaptureActivationDispatchesDuringSwiftUIInactivePhase() {
        let desktopSessionID = UUID()

        let decision = MirageStreamForegroundRecoveryPolicy.decisionForInputCaptureApplicationActivation(
            swiftUIScenePhase: .inactive,
            isDesktopStream: true,
            activeDesktopSessionID: desktopSessionID,
            hasPresentedFrame: true,
            hasController: true
        )

        #expect(decision == .dispatch(swiftUIScenePhase: .inactive))
    }

    @Test("Desktop foreground recovery skips inactive desktop streams")
    func desktopRecoverySkipsInactiveDesktopStream() {
        let decision = MirageStreamForegroundRecoveryPolicy.decisionForInputCaptureApplicationActivation(
            swiftUIScenePhase: .active,
            isDesktopStream: true,
            activeDesktopSessionID: nil,
            hasPresentedFrame: true,
            hasController: true
        )

        #expect(decision == .skipInactiveDesktopStream)
    }

    @Test("Desktop foreground recovery skips before first frame")
    func desktopRecoverySkipsBeforeFirstFrame() {
        let desktopSessionID = UUID()

        let decision = MirageStreamForegroundRecoveryPolicy.decisionForInputCaptureApplicationActivation(
            swiftUIScenePhase: .active,
            isDesktopStream: true,
            activeDesktopSessionID: desktopSessionID,
            hasPresentedFrame: false,
            hasController: true
        )

        #expect(decision == .skipBeforeFirstFrame(desktopSessionID: desktopSessionID))
    }

    @Test("Foreground recovery defers until controller is available")
    func recoveryDefersUntilControllerAvailable() {
        let desktopSessionID = UUID()

        let decision = MirageStreamForegroundRecoveryPolicy.decisionForInputCaptureApplicationActivation(
            swiftUIScenePhase: .inactive,
            isDesktopStream: true,
            activeDesktopSessionID: desktopSessionID,
            hasPresentedFrame: true,
            hasController: false
        )

        #expect(decision == .deferUntilControllerAvailable(swiftUIScenePhase: .inactive))
    }

    @Test("Foreground probe fails host-healthy client decode underrun")
    func foregroundProbeFailsHostHealthyClientDecodeUnderrun() {
        let initial = MirageClientService.ForegroundStreamHealthSnapshot(
            streamID: 1,
            hasController: true,
            hasVideoMediaStream: true,
            latestPacketTime: 10,
            submittedSequence: 10,
            isAwaitingKeyframe: false,
            decodedFPS: 1,
            layerEnqueueFPS: 1,
            uniqueLayerEnqueueFPS: 1,
            decodeHealthy: false,
            severeDecodeUnderrun: true,
            clientRecoveryStatus: .idle,
            hostTargetFrameRate: 60,
            hostEncodedFPS: 60
        )
        let final = MirageClientService.ForegroundStreamHealthSnapshot(
            streamID: 1,
            hasController: true,
            hasVideoMediaStream: true,
            latestPacketTime: 11,
            submittedSequence: 11,
            isAwaitingKeyframe: false,
            decodedFPS: 1,
            layerEnqueueFPS: 1,
            uniqueLayerEnqueueFPS: 1,
            decodeHealthy: false,
            severeDecodeUnderrun: true,
            clientRecoveryStatus: .idle,
            hostTargetFrameRate: 60,
            hostEncodedFPS: 60
        )

        if case .healthy = MirageClientService.foregroundStreamHealthProbeDisposition(
            initial: initial,
            final: final
        ) {
            Issue.record("Expected foreground probe to fail decode underrun")
        }
    }

    @Test("Foreground probe accepts stable decoded presentation")
    func foregroundProbeAcceptsStableDecodedPresentation() {
        let initial = MirageClientService.ForegroundStreamHealthSnapshot(
            streamID: 1,
            hasController: true,
            hasVideoMediaStream: true,
            latestPacketTime: 10,
            submittedSequence: 10,
            isAwaitingKeyframe: false,
            decodedFPS: 45,
            layerEnqueueFPS: 45,
            uniqueLayerEnqueueFPS: 45,
            visibleFrameFPS: 45,
            visibleFrameCadenceKnown: true,
            hostTargetFrameRate: 60,
            hostEncodedFPS: 60
        )
        let final = MirageClientService.ForegroundStreamHealthSnapshot(
            streamID: 1,
            hasController: true,
            hasVideoMediaStream: true,
            latestPacketTime: 11,
            submittedSequence: 70,
            isAwaitingKeyframe: false,
            decodedFPS: 58,
            layerEnqueueFPS: 58,
            uniqueLayerEnqueueFPS: 58,
            visibleFrameFPS: 58,
            visibleFrameCadenceKnown: true,
            hostTargetFrameRate: 60,
            hostEncodedFPS: 60
        )

        #expect(
            MirageClientService.foregroundStreamHealthProbeDisposition(
                initial: initial,
                final: final
            ) == .healthy
        )
    }

    @Test("Recovery keyframe retry waits for stabilization frames")
    func recoveryKeyframeRetryWaitsForStabilizationFrames() {
        let early = MirageClientService.recoveryKeyframeRetryDisposition(
            baselineSubmittedSequence: 10,
            latestSubmittedSequence: 11,
            previousPacketTime: 20,
            latestPacketTime: 21,
            awaitingKeyframe: false
        )
        let stable = MirageClientService.recoveryKeyframeRetryDisposition(
            baselineSubmittedSequence: 10,
            latestSubmittedSequence: 13,
            previousPacketTime: 20,
            latestPacketTime: 21,
            awaitingKeyframe: false
        )

        #expect(early == .retry(packetFlowResumed: true, awaitingKeyframe: false))
        #expect(stable == .recovered)
    }
}
