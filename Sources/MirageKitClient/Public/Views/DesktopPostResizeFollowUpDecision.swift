//
//  DesktopPostResizeFollowUpDecision.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/8/26.
//
//  Desktop follow-up resize dispatch after acknowledgement.
//

import CoreGraphics

enum DesktopPostResizeFollowUpDecision: Equatable {
    case noPendingResize
    case awaitFirstPresentedFrame
    case flushPendingResize
}

func desktopPostResizeFollowUpDecision(
    pendingTargetDisplaySize: CGSize,
    awaitingPostResizeFirstFrame: Bool
)
-> DesktopPostResizeFollowUpDecision {
    guard pendingTargetDisplaySize.width > 0, pendingTargetDisplaySize.height > 0 else {
        return .noPendingResize
    }

    if awaitingPostResizeFirstFrame {
        return .awaitFirstPresentedFrame
    }

    return .flushPendingResize
}
