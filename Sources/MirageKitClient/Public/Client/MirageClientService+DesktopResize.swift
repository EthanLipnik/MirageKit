//
//  MirageClientService+DesktopResize.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/13/26.
//

import CoreGraphics
import Foundation
import MirageKit

@MainActor
extension MirageClientService {
    private static let desktopResizeSendDebounce: Duration = .milliseconds(120)

    func desktopResizeTarget(
        for logicalResolution: CGSize,
        maxDrawableSize: CGSize?
    )
    -> DesktopResizeCoordinator.RequestGeometry? {
        let logicalResolution = scaledDisplayResolution(logicalResolution)
        guard logicalResolution.width > 0, logicalResolution.height > 0 else { return nil }

        let displayScaleFactor = resolvedDisplayScaleFactor(
            for: logicalResolution,
            explicitScaleFactor: nil
        ) ?? 1.0
        let encoderMaxWidth: Int? = if let maxDrawableSize, maxDrawableSize.width > 0 {
            Int(maxDrawableSize.width.rounded(.down))
        } else {
            nil
        }
        let encoderMaxHeight: Int? = if let maxDrawableSize, maxDrawableSize.height > 0 {
            Int(maxDrawableSize.height.rounded(.down))
        } else {
            nil
        }

        return DesktopResizeCoordinator.RequestGeometry(
            logicalResolution: logicalResolution,
            displayScaleFactor: displayScaleFactor,
            requestedStreamScale: clampedStreamScale(),
            encoderMaxWidth: encoderMaxWidth,
            encoderMaxHeight: encoderMaxHeight
        )
    }

    public var hasActivePostResizeTransition: Bool {
        desktopResizeCoordinator.activeTransition != nil ||
            !sessionStore.postResizeAwaitingFirstFrameStreamIDs.isEmpty
    }

    func queueDesktopResize(
        streamID: StreamID,
        target: DesktopResizeCoordinator.RequestGeometry?,
        hasPresentedFrame: Bool,
        useHostResolution: Bool
    ) {
        let coordinator = desktopResizeCoordinator
        guard pendingLocalDesktopStopStreamID != streamID else {
            coordinator.clearAllState()
            sessionStore.clearPostResizeTransition(for: streamID)
            return
        }

        if useHostResolution || target == nil {
            coordinator.cancelPendingTasks()
            coordinator.latestRequestedTarget = nil
            coordinator.queuedTarget = nil
            coordinator.lastSentTarget = nil
            coordinator.activeTransition = nil
            coordinator.clearLocalPresentationState()
            return
        }

        guard let target else { return }
        coordinator.latestRequestedTarget = target
        guard coordinator.resizeLifecycleState == .active else {
            coordinator.displayResolutionTask?.cancel()
            coordinator.displayResolutionTask = nil
            coordinator.queuedTarget = nil
            coordinator.clearLocalPresentationState()
            return
        }

        if sessionStore.isAwaitingPostResizeFirstFrame(for: streamID) {
            coordinator.queuedTarget = nil
            coordinator.clearLocalPresentationState()
            return
        }

        if let session = sessionStore.sessionByStreamID(streamID),
           session.clientRecoveryStatus != .idle {
            coordinator.queuedTarget = nil
            coordinator.clearLocalPresentationState()
            return
        }

        if let activeTransition = coordinator.activeTransition {
            if activeTransition.streamID == streamID, activeTransition.target == target {
                return
            }
            return
        }

        guard hasPresentedFrame else {
            coordinator.queuedTarget = target
            coordinator.clearLocalPresentationState()
            return
        }

        guard coordinator.lastSentTarget != target else {
            coordinator.clearLocalPresentationState()
            return
        }

        coordinator.queuedTarget = target
        coordinator.displayResolutionTask?.cancel()
        coordinator.displayResolutionTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.desktopResizeSendDebounce)
            } catch {
                return
            }
            await self?.dispatchQueuedDesktopResizeIfNeeded(streamID: streamID)
        }
    }

    func dispatchQueuedDesktopResizeIfNeeded(streamID: StreamID) async {
        let coordinator = desktopResizeCoordinator
        coordinator.displayResolutionTask?.cancel()
        coordinator.displayResolutionTask = nil

        guard desktopStreamID == streamID else { return }
        guard pendingLocalDesktopStopStreamID != streamID else {
            clearDesktopResizeState(streamID: streamID)
            return
        }
        guard coordinator.resizeLifecycleState == .active else {
            coordinator.queuedTarget = nil
            coordinator.clearLocalPresentationState()
            return
        }
        guard !sessionStore.isAwaitingPostResizeFirstFrame(for: streamID) else { return }
        guard coordinator.activeTransition == nil else { return }
        guard let target = coordinator.queuedTarget ?? coordinator.latestRequestedTarget else { return }
        guard target.logicalResolution.width > 0, target.logicalResolution.height > 0 else { return }
        guard coordinator.lastSentTarget != target else {
            coordinator.clearLocalPresentationState()
            return
        }

        let transitionID = UUID()
        coordinator.beginTransition(
            streamID: streamID,
            transitionID: transitionID,
            target: target
        )
        do {
            try await sendDesktopResizeRequest(
                streamID: streamID,
                newResolution: target.logicalResolution,
                transitionID: transitionID,
                requestedDisplayScaleFactor: target.displayScaleFactor,
                requestedStreamScale: target.requestedStreamScale,
                encoderMaxWidth: target.encoderMaxWidth,
                encoderMaxHeight: target.encoderMaxHeight
            )
        } catch {
            if coordinator.activeTransition?.transitionID == transitionID {
                coordinator.activeTransition = nil
            }
            coordinator.queuedTarget = target
            coordinator.clearLocalPresentationState()
            MirageLogger.error(
                .client,
                error: error,
                message: "Failed to send desktop resize transition: "
            )
        }
    }

    func handleDesktopPresentationReady(streamID: StreamID) {
        Task { @MainActor [weak self] in
            await self?.dispatchQueuedDesktopResizeIfNeeded(streamID: streamID)
        }
    }

    func clearDesktopResizeState(
        streamID: StreamID,
        clearPostResizeState: Bool = true,
        preserveLifecycleState: Bool = false
    ) {
        desktopResizeCoordinator.clearAllState(preserveLifecycleState: preserveLifecycleState)
        if clearPostResizeState {
            sessionStore.clearPostResizeTransition(for: streamID)
        }
    }

    func cancelQueuedDesktopResizeForLocalPresentation(streamID: StreamID) {
        guard desktopStreamID == streamID else { return }
        let coordinator = desktopResizeCoordinator
        coordinator.displayResolutionTask?.cancel()
        coordinator.displayResolutionTask = nil
        coordinator.latestRequestedTarget = nil
        coordinator.queuedTarget = nil
        if coordinator.activeTransition == nil {
            coordinator.clearLocalPresentationState()
        }
    }
}
