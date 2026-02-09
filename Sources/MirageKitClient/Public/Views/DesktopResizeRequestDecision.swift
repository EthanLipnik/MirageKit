//
//  DesktopResizeRequestDecision.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/9/26.
//
//  Desktop resize request decision coverage for no-op suppression.
//

import CoreGraphics

enum DesktopResizeRequestDecision: Equatable {
    case send
    case skipNoOp
}

func desktopResizeRequestDecision(
    targetDisplaySize: CGSize,
    acknowledgedPixelSize: CGSize,
    pointScale: CGFloat = 2,
    mismatchThresholdPoints: CGFloat = 4
)
-> DesktopResizeRequestDecision {
    guard targetDisplaySize.width > 0, targetDisplaySize.height > 0 else { return .skipNoOp }
    guard acknowledgedPixelSize.width > 0, acknowledgedPixelSize.height > 0, pointScale > 0 else { return .send }

    let acknowledgedDisplaySize = CGSize(
        width: acknowledgedPixelSize.width / pointScale,
        height: acknowledgedPixelSize.height / pointScale
    )

    let widthMismatch = abs(acknowledgedDisplaySize.width - targetDisplaySize.width)
    let heightMismatch = abs(acknowledgedDisplaySize.height - targetDisplaySize.height)

    if widthMismatch <= mismatchThresholdPoints, heightMismatch <= mismatchThresholdPoints {
        return .skipNoOp
    }

    return .send
}
