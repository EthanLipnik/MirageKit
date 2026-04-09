//
//  DesktopResizeRecoveryKeyframeStrategy.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/8/26.
//
//  Desktop resize recovery-keyframe staging policy.
//

enum DesktopResizeRecoveryKeyframeStrategy: Equatable {
    case scheduleDuringReset
    case deferUntilResume
}

func desktopResizeRecoveryKeyframeStrategy(
    encodingSuspendedForResize: Bool
)
-> DesktopResizeRecoveryKeyframeStrategy {
    if encodingSuspendedForResize {
        return .deferUntilResume
    }

    return .scheduleDuringReset
}
