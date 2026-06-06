//
//  InputCapturingView+ActivationRecovery.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
#if os(iOS) || os(visionOS)
import UIKit

extension InputCapturingView {
    func recordPendingApplicationActivationHandling(
        _ decision: InputCapturingActivationRecoveryDecision,
        resignedActive: Bool,
        backgrounded: Bool,
        displayLayerFailed: Bool
    ) {
        if let existingDecision = pendingApplicationActivationDecision {
            pendingApplicationActivationDecision = existingDecision.merged(with: decision)
        } else {
            pendingApplicationActivationDecision = decision
        }
        pendingActivationResignedActive = pendingActivationResignedActive || resignedActive
        pendingActivationBackgrounded = pendingActivationBackgrounded || backgrounded
        pendingActivationDisplayLayerFailed = pendingActivationDisplayLayerFailed || displayLayerFailed
        if let desktopSessionID {
            pendingActivationDesktopSessionID = desktopSessionID
        }
    }

    func clearPendingApplicationActivationHandling(reason: String? = nil) {
        if let reason,
           pendingApplicationActivationDecision != nil {
            let streamIDText = streamID.map(String.init(describing:)) ?? "unbound"
            MirageLogger.client(
                "Clearing pending activation handling for stream \(streamIDText) (\(reason))"
            )
        }
        pendingApplicationActivationDecision = nil
        pendingActivationResignedActive = false
        pendingActivationBackgrounded = false
        pendingActivationDisplayLayerFailed = false
        pendingActivationDesktopSessionID = nil
    }

    func applyPendingApplicationActivationHandlingIfPossible() {
        guard let activationDecision = pendingApplicationActivationDecision else { return }
        guard inputCapturingCanApplyPendingDisplayActivationHandling(
            hasWindow: window != nil,
            sceneActivationState: window?.windowScene?.activationState
        ) else {
            let streamIDText = streamID.map(String.init(describing:)) ?? "unbound"
            MirageLogger.client(
                "Deferring pending activation recovery for stream \(streamIDText); " +
                    "sceneState=\(String(describing: window?.windowScene?.activationState))"
            )
            return
        }
        let recoveryDisposition = inputCapturingPendingActivationRecoveryDisposition(
            activationDecision: activationDecision,
            pendingDesktopSessionID: pendingActivationDesktopSessionID,
            activeDesktopSessionID: desktopSessionID,
            hasPresentedFrame: hasPresentedFrameForActivationRecovery
        )
        guard recoveryDisposition == .applyPendingHandling else {
            let streamIDText = streamID.map(String.init(describing:)) ?? "unbound"
            MirageLogger.client(
                "Discarding pending activation recovery for stream \(streamIDText): pendingSession=\(pendingActivationDesktopSessionID?.uuidString ?? "nil"), activeSession=\(desktopSessionID?.uuidString ?? "nil"), hasPresentedFrame=\(hasPresentedFrameForActivationRecovery)"
            )
            clearPendingApplicationActivationHandling()
            return
        }

        sampleBufferView.resumeRenderingAfterApplicationActivation(
            resetPresentationState: activationDecision.shouldResetPresentationState
        )

        if activationDecision.shouldRequestStreamRecovery {
            let streamIDText = streamID.map(String.init(describing:)) ?? "unbound"
            MirageLogger.client(
                "Activation recovery requested for stream \(streamIDText) " +
                    "(resignedActive=\(pendingActivationResignedActive), " +
                    "backgrounded=\(pendingActivationBackgrounded), " +
                    "displayLayerFailed=\(pendingActivationDisplayLayerFailed), " +
                    "session=\(pendingActivationDesktopSessionID?.uuidString ?? "nil"))"
            )
            onBecomeActive?()
        }

        clearPendingApplicationActivationHandling()
    }
}
#endif
