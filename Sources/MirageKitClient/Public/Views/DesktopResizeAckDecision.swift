//
//  DesktopResizeAckDecision.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/8/26.
//
//  Desktop resize acknowledgement convergence decisions.
//

import CoreGraphics

enum DesktopResizeAckDecision: Equatable {
    case converged
    case requestCorrection
    case waitForTimeout
}

func desktopResizeAckDecision(
    acknowledgedDisplaySize: CGSize,
    targetDisplaySize: CGSize,
    correctionAlreadySent: Bool,
    mismatchThresholdPoints: CGFloat = 4
)
-> DesktopResizeAckDecision {
    guard acknowledgedDisplaySize.width > 0, acknowledgedDisplaySize.height > 0 else {
        return correctionAlreadySent ? .waitForTimeout : .requestCorrection
    }
    guard targetDisplaySize.width > 0, targetDisplaySize.height > 0 else {
        return .converged
    }

    let widthMismatch = abs(acknowledgedDisplaySize.width - targetDisplaySize.width)
    let heightMismatch = abs(acknowledgedDisplaySize.height - targetDisplaySize.height)
    if widthMismatch <= mismatchThresholdPoints, heightMismatch <= mismatchThresholdPoints {
        return .converged
    }

    return correctionAlreadySent ? .waitForTimeout : .requestCorrection
}
