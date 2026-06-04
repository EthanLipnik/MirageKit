//
//  MirageStreamContentView+LifecycleRecovery.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/10/26.
//

import Foundation
import MirageKit
import SwiftUI

#if os(iOS) || os(visionOS)
/// SwiftUI scene phase value normalized for foreground-recovery logging.
private enum MirageStreamForegroundRecoverySwiftUIScenePhase: Equatable {
    case active
    case inactive
    case background
    case unknown

    init(_ scenePhase: ScenePhase) {
        switch scenePhase {
        case .active:
            self = .active
        case .inactive:
            self = .inactive
        case .background:
            self = .background
        @unknown default:
            self = .unknown
        }
    }

    var logLabel: String {
        switch self {
        case .active:
            "active"
        case .inactive:
            "inactive"
        case .background:
            "background"
        case .unknown:
            "unknown"
        }
    }
}

@MainActor
extension MirageStreamContentView {
    /// Applies resize lifecycle state transitions when SwiftUI/ UIKit suspends resizing.
    func handleResizeLifecycleSuspension(event: DesktopResizeLifecycleEvent) {
        let currentLifecycleState = isDesktopStream
            ? desktopResizeCoordinator.resizeLifecycleState
            : resizeLifecycleState
        let lifecycleDecision = desktopResizeLifecycleDecision(
            state: currentLifecycleState,
            event: event
        )
        if isDesktopStream {
            desktopResizeCoordinator.resizeLifecycleState = lifecycleDecision.nextState
        } else {
            resizeLifecycleState = lifecycleDecision.nextState
        }
        guard lifecycleDecision.nextState == .suspended else { return }
        cancelPendingResizeWorkForLifecycleSuspension()
    }

    /// Cancels delayed resize work when the stream surface leaves the active lifecycle.
    func cancelPendingResizeWorkForLifecycleSuspension() {
        resizeHoldoffTask?.cancel()
        resizeHoldoffTask = nil
        displayResolutionTask?.cancel()
        displayResolutionTask = nil
        appResizeDispatchState.cancel()
        streamScaleTask?.cancel()
        streamScaleTask = nil
        appResizeAckTimeoutTask?.cancel()
        appResizeAckTimeoutTask = nil
        if awaitingAppResizeAck {
            onAppResizeWaitingChanged?(false)
        }
        awaitingAppResizeAck = false
        appResizeBaselineAcknowledgement = nil
        latestContainerDisplaySize = .zero
        latestDrawableViewSize = .zero
        MirageClientService.clearCachedDisplayMetrics()
        if isResizing { isResizing = false }
        clientService.clearDesktopResizeState(
            streamID: session.streamID,
            preserveLifecycleState: isDesktopStream,
            preserveLastSentTarget: isDesktopStream
        )
    }

    /// Debounces resize dispatch after returning to foreground.
    func scheduleResizeHoldoff() {
        let updateLifecycleState: (DesktopResizeLifecycleState) -> Void = { nextState in
            if isDesktopStream {
                desktopResizeCoordinator.resizeLifecycleState = nextState
            } else {
                resizeLifecycleState = nextState
            }
        }
        let currentLifecycleState: () -> DesktopResizeLifecycleState = {
            if isDesktopStream {
                return desktopResizeCoordinator.resizeLifecycleState
            }
            return resizeLifecycleState
        }

        if isDesktopStream {
            desktopResizeCoordinator.resizeHoldoffTask?.cancel()
        } else {
            resizeHoldoffTask?.cancel()
        }
        updateLifecycleState(.suspended)
        let holdoffTask = Task { @MainActor in
            do {
                try await Task.sleep(for: Self.foregroundResizeDebounce)
            } catch {
                return
            }
            let lifecycleDecision = desktopResizeLifecycleDecision(
                state: currentLifecycleState(),
                event: .foregroundHoldoffElapsed
            )
            updateLifecycleState(lifecycleDecision.nextState)
            if isDesktopStream, lifecycleDecision.nextState == .active {
                scheduleDesktopResizeForCurrentMetricsIfNeeded()
            }
        }
        if isDesktopStream {
            desktopResizeCoordinator.resizeHoldoffTask = holdoffTask
        } else {
            resizeHoldoffTask = holdoffTask
        }
    }

    /// Requests stream recovery when the app returns to foreground with an active stream.
    func handleForegroundRecovery() {
        let swiftUIScenePhase = MirageStreamForegroundRecoverySwiftUIScenePhase(scenePhase)
        scheduleResizeHoldoff()

        if isDesktopStream {
            guard let activeDesktopSessionID else {
                MirageLogger.client(
                    "Foreground recovery skipped for inactive desktop stream \(session.streamID)"
                )
                return
            }
            guard session.hasPresentedFrame else {
                MirageLogger.client(
                    "Foreground recovery skipped before first frame for stream \(session.streamID), session=\(activeDesktopSessionID.uuidString)"
                )
                return
            }
        }

        logForegroundRecoveryDispatch(swiftUIScenePhase: swiftUIScenePhase)
        clientService.requestStreamRecovery(for: session.streamID, trigger: .applicationActivation)
    }

    /// Logs which foreground signal triggered recovery.
    private func logForegroundRecoveryDispatch(
        swiftUIScenePhase: MirageStreamForegroundRecoverySwiftUIScenePhase
    ) {
        if swiftUIScenePhase == .active {
            MirageLogger.client("Foreground recovery dispatch for stream \(session.streamID)")
        } else {
            MirageLogger.client(
                "Foreground recovery dispatch for stream \(session.streamID) after UIKit-confirmed " +
                    "activation while SwiftUI scenePhase=\(swiftUIScenePhase.logLabel)"
            )
        }
    }
}
#endif
