import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
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
}

enum DesktopResizeLifecycleEvent: Equatable {
    case willResignActive
    case didEnterBackground
    case foregroundHoldoffElapsed
    case containerSizeChanged
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
    case (_, .didEnterBackground):
        return DesktopResizeLifecycleDecision(
            nextState: .suspended,
            shouldProcessDrawableMetrics: false
        )

    case (.suspended, .foregroundHoldoffElapsed):
        return DesktopResizeLifecycleDecision(
            nextState: .active,
            shouldProcessDrawableMetrics: false
        )

    case (.active, .containerSizeChanged),
         (.active, .drawableMetricsChanged):
        return DesktopResizeLifecycleDecision(
            nextState: .active,
            shouldProcessDrawableMetrics: true
        )

    case (.active, .willResignActive),
         (.active, .foregroundHoldoffElapsed),
         (.suspended, .containerSizeChanged),
         (.suspended, .drawableMetricsChanged),
         (.suspended, .willResignActive):
        return DesktopResizeLifecycleDecision(
            nextState: state,
            shouldProcessDrawableMetrics: false
        )
    }
}
