//
//  DesktopResizeLifecycleDecision.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/30/26.
//
//  Desktop resize lifecycle policy for background suppression.
//

enum DesktopResizeLifecycleState: Equatable {
    case active
    case suspended
    case awaitingFreshActiveMetrics
}

enum DesktopResizeLifecycleEvent: Equatable {
    case willResignActive
    case didEnterBackground
    case foregroundHoldoffElapsed
    case drawableMetricsChanged
}

struct DesktopResizeLifecycleDecision: Equatable {
    let nextState: DesktopResizeLifecycleState
    let shouldProcessDrawableMetrics: Bool
}

func desktopResizeLifecycleDecision(
    state: DesktopResizeLifecycleState,
    event: DesktopResizeLifecycleEvent
) -> DesktopResizeLifecycleDecision {
    switch (state, event) {
    case (_, .willResignActive),
         (_, .didEnterBackground):
        return DesktopResizeLifecycleDecision(
            nextState: .suspended,
            shouldProcessDrawableMetrics: false
        )

    case (.suspended, .foregroundHoldoffElapsed):
        return DesktopResizeLifecycleDecision(
            nextState: .awaitingFreshActiveMetrics,
            shouldProcessDrawableMetrics: false
        )

    case (.awaitingFreshActiveMetrics, .drawableMetricsChanged):
        return DesktopResizeLifecycleDecision(
            nextState: .active,
            shouldProcessDrawableMetrics: true
        )

    case (.active, .drawableMetricsChanged):
        return DesktopResizeLifecycleDecision(
            nextState: .active,
            shouldProcessDrawableMetrics: true
        )

    case (.awaitingFreshActiveMetrics, .foregroundHoldoffElapsed),
         (.active, .foregroundHoldoffElapsed),
         (.suspended, .drawableMetricsChanged):
        return DesktopResizeLifecycleDecision(
            nextState: state,
            shouldProcessDrawableMetrics: false
        )
    }
}
