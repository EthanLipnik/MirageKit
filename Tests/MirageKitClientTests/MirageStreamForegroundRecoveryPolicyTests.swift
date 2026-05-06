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
}
