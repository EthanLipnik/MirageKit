//
//  WindowDrivenResizeTargetDecision.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/7/26.
//
//  Host resize targeting policy for platform window/container metrics.
//

import CoreGraphics

enum WindowDrivenResizeTargetDecision: Equatable {
    case useContainerSize(CGSize)
    case suppressForLocalPresentation
    case ignoreInvalidMetrics
}

func windowDrivenResizeTargetDecision(
    containerSize: CGSize,
    fallbackDrawableSize: CGSize = .zero,
    suppressForLocalPresentation: Bool
) -> WindowDrivenResizeTargetDecision {
    if suppressForLocalPresentation {
        return .suppressForLocalPresentation
    }

    if containerSize.width > 0, containerSize.height > 0 {
        return .useContainerSize(containerSize)
    }

    if fallbackDrawableSize.width > 0, fallbackDrawableSize.height > 0 {
        return .useContainerSize(fallbackDrawableSize)
    }

    return .ignoreInvalidMetrics
}
