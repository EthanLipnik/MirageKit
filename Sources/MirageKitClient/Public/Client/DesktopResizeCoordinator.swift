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
    enum DispatchPolicy: Equatable {
        case startup
        case immediate
        case settledWindowMetrics
    }

    struct RequestGeometry: Equatable {
        let logicalResolution: CGSize
        let displayScaleFactor: CGFloat
        let requestedStreamScale: CGFloat
        let encoderMaxWidth: Int?
        let encoderMaxHeight: Int?

        func isEffectivelySameStreamGeometry(as other: RequestGeometry) -> Bool {
            guard Self.approximatelyEqual(logicalResolution.width, other.logicalResolution.width),
                  Self.approximatelyEqual(logicalResolution.height, other.logicalResolution.height),
                  Self.approximatelyEqual(displayScaleFactor, other.displayScaleFactor),
                  Self.approximatelyEqual(requestedStreamScale, other.requestedStreamScale) else {
                return false
            }

            let currentGeometry = resolvedGeometry
            let otherGeometry = other.resolvedGeometry
            return Self.pixelSizesEqual(currentGeometry.displayPixelSize, otherGeometry.displayPixelSize) &&
                Self.pixelSizesEqual(currentGeometry.encodedPixelSize, otherGeometry.encodedPixelSize)
        }

        private var resolvedGeometry: MirageStreamGeometry {
            MirageStreamGeometry.resolve(
                logicalSize: logicalResolution,
                displayScaleFactor: displayScaleFactor,
                requestedStreamScale: requestedStreamScale,
                encoderMaxWidth: encoderMaxWidth,
                encoderMaxHeight: encoderMaxHeight
            )
        }

        private static func approximatelyEqual(_ lhs: CGFloat, _ rhs: CGFloat) -> Bool {
            abs(lhs - rhs) <= 0.001
        }

        private static func pixelSizesEqual(_ lhs: CGSize, _ rhs: CGSize) -> Bool {
            abs(lhs.width - rhs.width) <= 1 &&
                abs(lhs.height - rhs.height) <= 1
        }

        func isEffectivelySameAcceptedStreamGeometry(
            logicalResolution acceptedLogicalResolution: CGSize,
            displayPixelSize acceptedDisplayPixelSize: CGSize
        ) -> Bool {
            guard Self.approximatelyEqual(logicalResolution.width, acceptedLogicalResolution.width),
                  Self.approximatelyEqual(logicalResolution.height, acceptedLogicalResolution.height) else {
                return false
            }

            return Self.pixelSizesEqual(resolvedGeometry.displayPixelSize, acceptedDisplayPixelSize)
        }
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
    var latestRequestedDispatchPolicy: DispatchPolicy?
    var queuedTarget: RequestGeometry?
    var queuedDispatchPolicy: DispatchPolicy?
    var lastSentTarget: RequestGeometry?
    var activeTransition: ActiveTransition?
    @ObservationIgnored var displayResolutionTask: Task<Void, Never>?
    @ObservationIgnored var resizeHoldoffTask: Task<Void, Never>?
    @ObservationIgnored var presentationMaskTimeoutTask: Task<Void, Never>?
    @ObservationIgnored var activeTransitionTimeoutTask: Task<Void, Never>?

    func beginTransition(streamID: StreamID, transitionID: UUID, target: RequestGeometry) {
        activeTransition = ActiveTransition(streamID: streamID, transitionID: transitionID, target: target)
        lastSentTarget = target
        queuedTarget = nil
        queuedDispatchPolicy = nil
        latestRequestedTarget = target
        latestRequestedDispatchPolicy = nil
        isResizing = true
        maskActive = true
    }

    func queueLatestTarget(
        _ target: RequestGeometry,
        dispatchPolicy: DispatchPolicy = .settledWindowMetrics,
        activatePresentationMask: Bool = true
    ) {
        latestRequestedTarget = target
        latestRequestedDispatchPolicy = dispatchPolicy
        queuedTarget = target
        queuedDispatchPolicy = dispatchPolicy
        if activatePresentationMask {
            isResizing = true
            maskActive = true
        }
    }

    func clearQueuedResizeRequest() {
        latestRequestedTarget = nil
        latestRequestedDispatchPolicy = nil
        queuedTarget = nil
        queuedDispatchPolicy = nil
        if activeTransition == nil {
            clearLocalPresentationState()
        }
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

    func finishTransition() {
        activeTransitionTimeoutTask?.cancel()
        activeTransitionTimeoutTask = nil
        activeTransition = nil
        if queuedTarget == nil {
            isResizing = false
            maskActive = false
        } else {
            isResizing = true
            maskActive = true
        }
    }

    func expireActiveTransition(streamID: StreamID, transitionID: UUID) -> Bool {
        guard let activeTransition,
              activeTransition.streamID == streamID,
              activeTransition.transitionID == transitionID else {
            return false
        }

        self.activeTransition = nil
        activeTransitionTimeoutTask?.cancel()
        activeTransitionTimeoutTask = nil
        if queuedTarget == nil {
            isResizing = false
            maskActive = false
        } else {
            isResizing = true
            maskActive = true
        }
        return true
    }

    func clearQueuedTargetsMatchingAcceptedStreamGeometry(
        logicalResolution acceptedLogicalResolution: CGSize,
        displayPixelSize acceptedDisplayPixelSize: CGSize
    ) {
        if queuedTarget?.isEffectivelySameAcceptedStreamGeometry(
            logicalResolution: acceptedLogicalResolution,
            displayPixelSize: acceptedDisplayPixelSize
        ) == true {
            queuedTarget = nil
            queuedDispatchPolicy = nil
        }

        if latestRequestedTarget?.isEffectivelySameAcceptedStreamGeometry(
            logicalResolution: acceptedLogicalResolution,
            displayPixelSize: acceptedDisplayPixelSize
        ) == true {
            latestRequestedTarget = nil
            latestRequestedDispatchPolicy = nil
        }

        if activeTransition == nil, queuedTarget == nil {
            clearLocalPresentationState()
        }
    }

    func clearLocalPresentationState() {
        isResizing = false
        maskActive = false
        presentationMaskTimeoutTask?.cancel()
        presentationMaskTimeoutTask = nil
    }

    func cancelPendingTasks() {
        displayResolutionTask?.cancel()
        displayResolutionTask = nil
        resizeHoldoffTask?.cancel()
        resizeHoldoffTask = nil
        presentationMaskTimeoutTask?.cancel()
        presentationMaskTimeoutTask = nil
        activeTransitionTimeoutTask?.cancel()
        activeTransitionTimeoutTask = nil
    }

    func cancelPendingResizeDispatch() {
        displayResolutionTask?.cancel()
        displayResolutionTask = nil
        if activeTransition == nil {
            clearLocalPresentationState()
        }
    }

    func clearAllState(
        preserveLifecycleState: Bool = false,
        preserveLastSentTarget: Bool = false
    ) {
        let lifecycleState = resizeLifecycleState
        let lastSentTarget = lastSentTarget
        cancelPendingTasks()
        resizeLifecycleState = preserveLifecycleState ? lifecycleState : .active
        clearLocalPresentationState()
        latestContainerDisplaySize = .zero
        latestDrawableViewSize = .zero
        latestRequestedTarget = nil
        latestRequestedDispatchPolicy = nil
        queuedTarget = nil
        queuedDispatchPolicy = nil
        self.lastSentTarget = preserveLastSentTarget ? lastSentTarget : nil
        activeTransition = nil
        activeTransitionTimeoutTask?.cancel()
        activeTransitionTimeoutTask = nil
    }
}
