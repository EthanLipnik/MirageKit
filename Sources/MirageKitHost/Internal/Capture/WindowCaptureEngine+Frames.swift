//
//  WindowCaptureEngine+Frames.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Frame handling helpers.
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
import CoreMedia
import CoreVideo
import Foundation
import os

#if os(macOS)
import AppKit
import ScreenCaptureKit

extension WindowCaptureEngine {
    func markCaptureRestartKeyframeRequested(
        restartStreak: Int,
        shouldEscalateRecovery: Bool
    ) {
        enqueuePendingKeyframeRequest(
            .captureRestart(
                restartStreak: restartStreak,
                shouldEscalateRecovery: shouldEscalateRecovery
            )
        )
    }

    private func enqueuePendingKeyframeRequest(_ reason: CaptureKeyframeRequestReason) {
        switch (pendingKeyframeRequest, reason) {
        case (.none, _):
            pendingKeyframeRequest = reason
        case let (.some(.captureRestart(existingStreak, existingEscalation)), .captureRestart(newStreak, newEscalation)):
            pendingKeyframeRequest = .captureRestart(
                restartStreak: max(existingStreak, newStreak),
                shouldEscalateRecovery: existingEscalation || newEscalation
            )
        }
    }

    func consumePendingKeyframeRequest() async -> CaptureKeyframeRequestReason? {
        if let pendingKeyframeRequest {
            self.pendingKeyframeRequest = nil
            return pendingKeyframeRequest
        }
        return nil
    }
}

#endif
