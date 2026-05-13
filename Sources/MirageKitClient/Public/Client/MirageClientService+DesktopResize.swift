//
//  MirageClientService+DesktopResize.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/13/26.
//

import CoreGraphics
import MirageKit

@MainActor
extension MirageClientService {
    func desktopResizeTarget(
        for logicalResolution: CGSize,
        maxDrawableSize: CGSize?
    )
    -> DesktopResizeCoordinator.RequestGeometry? {
        let logicalResolution = MirageStreamGeometry.normalizedLogicalSize(logicalResolution)
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
            requestedStreamScale: MirageStreamGeometry.clampStreamScale(resolutionScale),
            encoderMaxWidth: encoderMaxWidth,
            encoderMaxHeight: encoderMaxHeight
        )
    }

    /// Indicates whether desktop resize presentation masking is active.
    ///
    /// This remains true while the client is waiting for the first frame that reflects a
    /// requested resize, so UI can avoid exposing a stale frame during the transition.
    public var hasActivePostResizeTransition: Bool {
        desktopResizeCoordinator.activeTransition != nil ||
            !sessionStore.postResizeAwaitingFirstFrameStreamIDs.isEmpty
    }

    func queueDesktopResize(
        streamID: StreamID,
        target: DesktopResizeCoordinator.RequestGeometry?,
        hasPresentedFrame: Bool,
        useHostResolution: Bool,
        dispatchPolicy: DesktopResizeCoordinator.DispatchPolicy = .settledWindowMetrics
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
            coordinator.latestRequestedDispatchPolicy = nil
            coordinator.queuedTarget = nil
            coordinator.queuedDispatchPolicy = nil
            coordinator.lastSentTarget = nil
            coordinator.activeTransition = nil
            coordinator.clearLocalPresentationState()
            return
        }

        guard let target else { return }
        guard coordinator.lastSentTarget?.isEffectivelySameStreamGeometry(as: target) != true else {
            coordinator.displayResolutionTask?.cancel()
            coordinator.displayResolutionTask = nil
            coordinator.clearQueuedResizeRequest()
            return
        }
        guard coordinator.resizeLifecycleState == .active else {
            coordinator.queueLatestTarget(
                target,
                dispatchPolicy: dispatchPolicy,
                activatePresentationMask: false
            )
            coordinator.cancelPendingResizeDispatch()
            MirageLogger.client(
                "Desktop resize queued while lifecycle is suspended for stream \(streamID)"
            )
            return
        }

        if sessionStore.isAwaitingPostResizeFirstFrame(for: streamID) {
            coordinator.queueLatestTarget(target, dispatchPolicy: dispatchPolicy)
            scheduleDesktopResizePresentationMaskTimeout(streamID: streamID)
            MirageLogger.client(
                "Desktop resize queued while waiting for post-resize frame for stream \(streamID)"
            )
            return
        }

        if let session = sessionStore.sessionByStreamID(streamID),
           session.clientRecoveryStatus != .idle {
            coordinator.queueLatestTarget(target, dispatchPolicy: dispatchPolicy)
            scheduleDesktopResizePresentationMaskTimeout(streamID: streamID)
            MirageLogger.client(
                "Desktop resize queued during client recovery for stream \(streamID), status=\(session.clientRecoveryStatus)"
            )
            return
        }

        if let activeTransition = coordinator.activeTransition {
            if activeTransition.streamID == streamID,
               activeTransition.target.isEffectivelySameStreamGeometry(as: target) {
                return
            }
            coordinator.queueLatestTarget(target, dispatchPolicy: dispatchPolicy)
            scheduleDesktopResizePresentationMaskTimeout(streamID: streamID)
            MirageLogger.client(
                "Desktop resize queued behind active transition for stream \(streamID)"
            )
            return
        }

        guard hasPresentedFrame else {
            coordinator.queueLatestTarget(
                target,
                dispatchPolicy: .startup,
                activatePresentationMask: false
            )
            coordinator.cancelPendingResizeDispatch()
            coordinator.clearLocalPresentationState()
            return
        }

        if coordinator.queuedTarget?.isEffectivelySameStreamGeometry(as: target) == true,
           coordinator.queuedDispatchPolicy == dispatchPolicy {
            return
        }

        coordinator.queueLatestTarget(target, dispatchPolicy: dispatchPolicy)
        scheduleDesktopResizePresentationMaskTimeout(streamID: streamID)
        scheduleQueuedDesktopResizeIfNeeded(streamID: streamID)
    }

    func scheduleQueuedDesktopResizeIfNeeded(streamID: StreamID) {
        let coordinator = desktopResizeCoordinator
        guard coordinator.queuedTarget != nil else { return }
        let dispatchPolicy = coordinator.queuedDispatchPolicy ?? .settledWindowMetrics
        scheduleDesktopResizeDispatch(streamID: streamID, dispatchPolicy: dispatchPolicy)
    }

    private func scheduleDesktopResizeDispatch(
        streamID: StreamID,
        dispatchPolicy: DesktopResizeCoordinator.DispatchPolicy
    ) {
        let coordinator = desktopResizeCoordinator
        coordinator.displayResolutionTask?.cancel()
        coordinator.displayResolutionTask = Task { @MainActor [weak self] in
            do {
                let delay: Duration? = switch dispatchPolicy {
                case .startup, .immediate:
                    nil
                case .settledWindowMetrics:
                    self?.desktopResizeWindowSettlingDelay
                }
                if let delay {
                    try await Task.sleep(for: delay)
                }
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
            MirageLogger.client(
                "Desktop resize dispatch deferred while lifecycle is suspended for stream \(streamID)"
            )
            return
        }
        guard !sessionStore.isAwaitingPostResizeFirstFrame(for: streamID) else {
            scheduleQueuedDesktopResizeIfNeeded(streamID: streamID)
            return
        }
        guard coordinator.activeTransition == nil else {
            scheduleQueuedDesktopResizeIfNeeded(streamID: streamID)
            return
        }
        if let session = sessionStore.sessionByStreamID(streamID),
           session.clientRecoveryStatus != .idle {
            scheduleQueuedDesktopResizeIfNeeded(streamID: streamID)
            return
        }
        guard let target = coordinator.queuedTarget else { return }
        guard target.logicalResolution.width > 0, target.logicalResolution.height > 0 else { return }
        guard coordinator.lastSentTarget?.isEffectivelySameStreamGeometry(as: target) != true else {
            coordinator.clearQueuedResizeRequest()
            return
        }

        let transitionID = UUID()
        let dispatchPolicy = coordinator.queuedDispatchPolicy ?? .settledWindowMetrics
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
            coordinator.queueLatestTarget(
                target,
                dispatchPolicy: dispatchPolicy,
                activatePresentationMask: false
            )
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
            self?.scheduleQueuedDesktopResizeIfNeeded(streamID: streamID)
        }
    }

    func beginPostResizeTransition(
        streamID: StreamID,
        scheduleTimeout: Bool = true
    ) {
        sessionStore.beginPostResizeTransition(for: streamID)
        if scheduleTimeout {
            schedulePostResizeTransitionTimeoutIfNeeded(streamID: streamID)
        }
    }

    func handleStreamFirstFramePresented(streamID: StreamID) {
        let wasAwaitingPostResizeFrame = sessionStore.isAwaitingPostResizeFirstFrame(for: streamID)
        sessionStore.markFirstFramePresented(for: streamID)
        guard wasAwaitingPostResizeFrame else { return }
        finishPostResizeTransitionWait(streamID: streamID, reason: "presented-frame")
    }

    func schedulePostResizeTransitionTimeoutIfNeeded(streamID: StreamID) {
        guard sessionStore.isAwaitingPostResizeFirstFrame(for: streamID) else {
            postResizeTransitionTimeoutTasks[streamID]?.cancel()
            postResizeTransitionTimeoutTasks.removeValue(forKey: streamID)
            return
        }
        postResizeTransitionTimeoutTasks[streamID]?.cancel()
        postResizeTransitionTimeoutTasks[streamID] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: self?.desktopPostResizeTransitionTimeout ?? .seconds(10))
            } catch {
                return
            }
            guard let self else { return }
            guard sessionStore.isAwaitingPostResizeFirstFrame(for: streamID) else { return }
            MirageLogger.client(
                "Clearing local post-resize loading UI for stream \(streamID) after client-side timeout"
            )
            finishPostResizeTransitionWait(streamID: streamID, reason: "timeout")
        }
    }

    private func finishPostResizeTransitionWait(
        streamID: StreamID,
        reason: String,
        dispatchQueuedResize: Bool = true
    ) {
        postResizeTransitionTimeoutTasks[streamID]?.cancel()
        postResizeTransitionTimeoutTasks.removeValue(forKey: streamID)
        sessionStore.clearPostResizeTransition(for: streamID)
        desktopResizeCoordinator.clearLocalPresentationState()
        MirageLogger.client("Post-resize transition cleared for stream \(streamID) (\(reason))")
        if dispatchQueuedResize {
            handleDesktopPresentationReady(streamID: streamID)
        }
    }

    private func scheduleDesktopResizePresentationMaskTimeout(streamID: StreamID) {
        let coordinator = desktopResizeCoordinator
        coordinator.presentationMaskTimeoutTask?.cancel()
        coordinator.presentationMaskTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: self?.desktopPostResizeTransitionTimeout ?? .seconds(10))
            } catch {
                return
            }
            guard let self, desktopStreamID == streamID else { return }
            desktopResizeCoordinator.clearLocalPresentationState()
            MirageLogger.client(
                "Clearing local desktop resize mask for stream \(streamID) after client-side timeout"
            )
        }
    }

    func clearDesktopResizeState(
        streamID: StreamID,
        clearPostResizeState: Bool = true,
        preserveLifecycleState: Bool = false,
        preserveLastSentTarget: Bool = false
    ) {
        desktopResizeCoordinator.clearAllState(
            preserveLifecycleState: preserveLifecycleState,
            preserveLastSentTarget: preserveLastSentTarget
        )
        if clearPostResizeState {
            sessionStore.clearPostResizeTransition(for: streamID)
        }
        postResizeTransitionTimeoutTasks[streamID]?.cancel()
        postResizeTransitionTimeoutTasks.removeValue(forKey: streamID)
    }

    func cancelQueuedDesktopResizeForLocalPresentation(streamID: StreamID) {
        guard desktopStreamID == streamID else { return }
        let coordinator = desktopResizeCoordinator
        coordinator.displayResolutionTask?.cancel()
        coordinator.displayResolutionTask = nil
        coordinator.latestRequestedTarget = nil
        coordinator.latestRequestedDispatchPolicy = nil
        coordinator.queuedTarget = nil
        coordinator.queuedDispatchPolicy = nil
        if coordinator.activeTransition == nil {
            coordinator.clearLocalPresentationState()
        }
    }
}
