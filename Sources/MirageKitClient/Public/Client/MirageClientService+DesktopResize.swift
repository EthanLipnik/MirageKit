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
        maxDrawableSize: CGSize?,
        displayScaleFactor explicitDisplayScaleFactor: CGFloat? = nil
    )
    -> DesktopResizeCoordinator.RequestGeometry? {
        let logicalResolution = MirageStreamGeometry.normalizedLogicalSize(logicalResolution)
        guard logicalResolution.width > 0, logicalResolution.height > 0 else { return nil }

        let displayScaleFactor = resolvedDisplayScaleFactor(
            for: logicalResolution,
            explicitScaleFactor: explicitDisplayScaleFactor ?? desktopStreamDisplayScaleFactor
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
            refreshTargetHz: effectiveFrameRateForCurrentMediaPath(screenMaxRefreshRate),
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

    /// Human-readable desktop resize state included in support diagnostics.
    public var desktopResizeDiagnosticsSummary: String {
        let activeTransition = desktopResizeCoordinator.activeTransition.map { transition in
            "active(stream=\(transition.streamID), transition=\(transition.transitionID.uuidString), " +
                "contract=\(transition.target.contractID.uuidString))"
        } ?? "active=none"
        let lastSentTransition = desktopResizeCoordinator.lastSentTransition.map { transition in
            "lastSent(stream=\(transition.streamID), transition=\(transition.transitionID.uuidString), " +
                "contract=\(transition.target.contractID.uuidString))"
        } ?? "lastSent=none"
        let waitingStreams = sessionStore.postResizeAwaitingFirstFrameStreamIDs
            .sorted()
            .map(String.init)
            .joined(separator: ",")
        let waitingText = waitingStreams.isEmpty ? "none" : waitingStreams
        return "\(activeTransition) \(lastSentTransition) postResizeAwaitingFirstFrame=\(waitingText)"
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
            coordinator.clearAllState()
            sessionStore.clearPostResizeTransition(for: streamID)
            return
        }

        guard let target else { return }
        guard coordinator.lastSentTarget?.isEffectivelySameStreamGeometry(as: target) != true else {
            coordinator.displayResolutionTask?.cancel()
            coordinator.displayResolutionTask = nil
            coordinator.clearQueuedResizeRequest()
            return
        }
        if let lastSentTarget = coordinator.lastSentTarget,
           let acceptedDisplayPixelSize = desktopStreamResolution,
           let session = sessionStore.sessionByStreamID(streamID),
           session.clientRecoveryStatus == .startup,
           target.isImmediateStartupDowngrade(
               of: lastSentTarget,
               acceptedDisplayPixelSize: acceptedDisplayPixelSize
           ) {
            coordinator.displayResolutionTask?.cancel()
            coordinator.displayResolutionTask = nil
            coordinator.clearQueuedResizeRequest()
            MirageLogger.client(
                "Desktop startup resize downgrade suppressed for stream \(streamID): " +
                    "accepted=\(Int(acceptedDisplayPixelSize.width))x\(Int(acceptedDisplayPixelSize.height))px " +
                    "target=\(Int(target.displayPixelSize.width))x\(Int(target.displayPixelSize.height))px"
            )
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

        guard hasPresentedFrame else {
            coordinator.queueLatestTarget(
                target,
                dispatchPolicy: .settledWindowMetrics,
                activatePresentationMask: false
            )
            coordinator.cancelPendingResizeDispatch()
            coordinator.clearLocalPresentationState()
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
                encoderMaxHeight: target.encoderMaxHeight,
                desktopGeometryContractID: target.contractID,
                desktopGeometrySceneIdentity: target.sceneIdentity,
                desktopGeometryRefreshTargetHz: target.refreshTargetHz
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
        stopAppStreamPlaceholderDesktopIfNeeded(afterPresentedStreamID: streamID)
        guard wasAwaitingPostResizeFrame else { return }
        finishPostResizeTransitionWait(streamID: streamID, reason: "presented-frame")
    }

    private func stopAppStreamPlaceholderDesktopIfNeeded(afterPresentedStreamID streamID: StreamID) {
        guard let placeholderStreamID = appStreamPlaceholderDesktopStreamID,
              streamID != placeholderStreamID else {
            return
        }
        let isAppStream = sessionStore.sessionByMediaStreamID(streamID) != nil ||
            sessionStore.sessionByStreamID(streamID).map { $0.mediaStreamID != $0.streamID } == true
        guard isAppStream else { return }
        appStreamPlaceholderDesktopStreamID = nil
        appStreamPlaceholderAppSessionID = nil
        Task { @MainActor [weak self] in
            do {
                try await self?.stopDesktopStream()
            } catch {
                MirageLogger.error(.client, error: error, message: "Failed to stop app-stream placeholder desktop: ")
            }
        }
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

    func finishPostResizeTransitionWait(
        streamID: StreamID,
        reason: String,
        dispatchQueuedResize: Bool = true
    ) {
        postResizeTransitionTimeoutTasks[streamID]?.cancel()
        postResizeTransitionTimeoutTasks.removeValue(forKey: streamID)
        sessionStore.clearPostResizeTransition(for: streamID)
        desktopResizeCoordinator.clearLocalPresentationState()
        if reason == "timeout", let controller = controllersByStream[streamID] {
            Task {
                await controller.clearPostResizeRecoveryAfterLocalTimeout()
            }
        }
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

    func clearTransientDesktopResizeState(
        streamID: StreamID,
        preserveLifecycleState: Bool = false
    ) {
        desktopResizeCoordinator.clearTransientPresentationState(
            preserveLifecycleState: preserveLifecycleState
        )
        if !sessionStore.isAwaitingPostResizeFirstFrame(for: streamID) {
            postResizeTransitionTimeoutTasks[streamID]?.cancel()
            postResizeTransitionTimeoutTasks.removeValue(forKey: streamID)
        }
    }

    func handlePostResizePresentationTelemetry(streamID: StreamID) {
        guard sessionStore.isAwaitingPostResizeFirstFrame(for: streamID) else { return }
        finishPostResizeTransitionWait(streamID: streamID, reason: "presentation-telemetry")
    }

    func handlePostResizeSubmittedFrameTelemetryIfNeeded(streamID: StreamID) {
        guard sessionStore.isAwaitingPostResizeFirstFrame(for: streamID),
              let dimensionToken = desktopDimensionTokenByStream[streamID],
              MirageRenderStreamStore.shared.hasSubmittedFrame(for: streamID, dimensionToken: dimensionToken) else {
            return
        }
        finishPostResizeTransitionWait(streamID: streamID, reason: "dimension-token-presentation")
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
