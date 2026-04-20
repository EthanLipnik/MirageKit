//
//  DesktopResizeCoordinator.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/13/26.
//

import CoreGraphics
import Foundation
import MirageKit
import Observation

@Observable
@MainActor
final class DesktopResizeCoordinator {
    struct RequestGeometry: Equatable {
        let logicalResolution: CGSize
        let displayScaleFactor: CGFloat
        let requestedStreamScale: CGFloat
        let encoderMaxWidth: Int?
        let encoderMaxHeight: Int?
    }

    struct ActiveTransition: Equatable {
        let streamID: StreamID
        let transitionID: UUID
        let target: RequestGeometry
    }

    var resizeLifecycleState: DesktopResizeLifecycleState = .active
    var isResizing = false
    var maskActive = false
    var latestContainerDisplaySize: CGSize = .zero
    var latestDrawableViewSize: CGSize = .zero
    var latestRequestedTarget: RequestGeometry?
    var queuedTarget: RequestGeometry?
    var lastSentTarget: RequestGeometry?
    var activeTransition: ActiveTransition?
    private var requiresStableForegroundMetrics = false
    private var foregroundCandidateTarget: RequestGeometry?
    private var foregroundCandidateCount = 0
    @ObservationIgnored var displayResolutionTask: Task<Void, Never>?
    @ObservationIgnored var resizeHoldoffTask: Task<Void, Never>?

    func beginTransition(streamID: StreamID, transitionID: UUID, target: RequestGeometry) {
        activeTransition = ActiveTransition(streamID: streamID, transitionID: transitionID, target: target)
        lastSentTarget = target
        queuedTarget = nil
        latestRequestedTarget = target
        isResizing = true
        maskActive = true
    }

    func queueLatestTarget(_ target: RequestGeometry) {
        latestRequestedTarget = target
        queuedTarget = target
    }

    func acceptTransition(streamID: StreamID, transitionID: UUID?) -> Bool {
        guard let transitionID,
              let activeTransition,
              activeTransition.streamID == streamID,
              activeTransition.transitionID == transitionID else {
            return false
        }
        return true
    }

    func finishTransition(outcome _: MirageDesktopTransitionOutcome?) {
        activeTransition = nil
        if queuedTarget == nil {
            isResizing = false
            maskActive = false
        } else {
            isResizing = true
            maskActive = true
        }
    }

    func clearLocalPresentationState() {
        isResizing = false
        maskActive = false
    }

    func beginForegroundResizeStabilization() {
        requiresStableForegroundMetrics = true
        foregroundCandidateTarget = nil
        foregroundCandidateCount = 0
    }

    func shouldAcceptForegroundResizeTarget(_ target: RequestGeometry) -> Bool {
        guard requiresStableForegroundMetrics else { return true }

        if lastSentTarget == target {
            clearForegroundResizeStabilization()
            return true
        }

        if foregroundCandidateTarget == target {
            foregroundCandidateCount += 1
        } else {
            foregroundCandidateTarget = target
            foregroundCandidateCount = 1
        }

        let requiredSampleCount = if let lastSentTarget,
                                     Self.hasDifferentOrientation(target, lastSentTarget) {
            4
        } else {
            2
        }
        guard foregroundCandidateCount >= requiredSampleCount else { return false }
        clearForegroundResizeStabilization()
        return true
    }

    func clearForegroundResizeStabilization() {
        requiresStableForegroundMetrics = false
        foregroundCandidateTarget = nil
        foregroundCandidateCount = 0
    }

    private static func hasDifferentOrientation(
        _ lhs: RequestGeometry,
        _ rhs: RequestGeometry
    ) -> Bool {
        let lhsIsLandscape = lhs.logicalResolution.width >= lhs.logicalResolution.height
        let rhsIsLandscape = rhs.logicalResolution.width >= rhs.logicalResolution.height
        return lhsIsLandscape != rhsIsLandscape
    }

    func cancelPendingTasks() {
        displayResolutionTask?.cancel()
        displayResolutionTask = nil
        resizeHoldoffTask?.cancel()
        resizeHoldoffTask = nil
    }

    func clearAllState(preserveLifecycleState: Bool = false) {
        let lifecycleState = resizeLifecycleState
        cancelPendingTasks()
        resizeLifecycleState = preserveLifecycleState ? lifecycleState : .active
        clearLocalPresentationState()
        latestContainerDisplaySize = .zero
        latestDrawableViewSize = .zero
        latestRequestedTarget = nil
        queuedTarget = nil
        lastSentTarget = nil
        activeTransition = nil
        if !preserveLifecycleState {
            clearForegroundResizeStabilization()
        }
    }
}
