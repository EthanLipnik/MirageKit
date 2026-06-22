//
//  DesktopResizeCoordinator.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/13/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import CoreGraphics
import Foundation
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
        private static let duplicateLogicalTolerance: CGFloat = 2
        private static let duplicatePixelTolerance: CGFloat = 32

        let contractID: UUID
        let sceneIdentity: String?
        let refreshTargetHz: Int?
        let logicalResolution: CGSize
        let displayScaleFactor: CGFloat
        let requestedStreamScale: CGFloat
        let encoderMaxWidth: Int?
        let encoderMaxHeight: Int?
        let disableResolutionCap: Bool

        init(
            contractID: UUID = UUID(),
            sceneIdentity: String? = nil,
            refreshTargetHz: Int? = nil,
            logicalResolution: CGSize,
            displayScaleFactor: CGFloat,
            requestedStreamScale: CGFloat,
            encoderMaxWidth: Int?,
            encoderMaxHeight: Int?,
            disableResolutionCap: Bool = false
        ) {
            self.contractID = contractID
            self.sceneIdentity = sceneIdentity?.isEmpty == false ? sceneIdentity : nil
            self.refreshTargetHz = refreshTargetHz.map { max(1, $0) }
            self.logicalResolution = logicalResolution
            self.displayScaleFactor = displayScaleFactor
            self.requestedStreamScale = requestedStreamScale
            self.encoderMaxWidth = encoderMaxWidth
            self.encoderMaxHeight = encoderMaxHeight
            self.disableResolutionCap = disableResolutionCap
        }

        func isEffectivelySameStreamGeometry(as other: RequestGeometry) -> Bool {
            contract.identity == other.contract.identity
        }

        func isRedundantWindowResizeTarget(as other: RequestGeometry) -> Bool {
            if isEffectivelySameStreamGeometry(as: other) {
                return true
            }

            guard disableResolutionCap == other.disableResolutionCap,
                  Self.sizesEqual(
                      logicalResolution,
                      other.logicalResolution,
                      tolerance: Self.duplicateLogicalTolerance
                  ) else {
                return false
            }

            return Self.sizesEqual(
                resolvedGeometry.displayPixelSize,
                other.resolvedGeometry.displayPixelSize,
                tolerance: Self.duplicatePixelTolerance
            ) &&
                Self.sizesEqual(
                    resolvedGeometry.encodedPixelSize,
                    other.resolvedGeometry.encodedPixelSize,
                    tolerance: Self.duplicatePixelTolerance
                )
        }

        private var resolvedGeometry: MirageMedia.MirageStreamGeometry {
            MirageMedia.MirageStreamGeometry.resolve(
                logicalSize: logicalResolution,
                displayScaleFactor: displayScaleFactor,
                requestedStreamScale: requestedStreamScale,
                encoderMaxWidth: encoderMaxWidth,
                encoderMaxHeight: encoderMaxHeight,
                disableResolutionCap: disableResolutionCap
            )
        }

        private var contract: MirageMedia.DesktopGeometryContract {
            MirageMedia.DesktopGeometryContract(
                contractID: contractID,
                sceneIdentity: sceneIdentity,
                refreshTargetHz: refreshTargetHz,
                logicalSize: logicalResolution,
                requestedDisplayScaleFactor: displayScaleFactor,
                requestedStreamScale: requestedStreamScale,
                encoderMaxWidth: encoderMaxWidth,
                encoderMaxHeight: encoderMaxHeight,
                disableResolutionCap: disableResolutionCap
            )
        }

        var displayPixelSize: CGSize {
            resolvedGeometry.displayPixelSize
        }

        private static func approximatelyEqual(_ lhs: CGFloat, _ rhs: CGFloat) -> Bool {
            abs(lhs - rhs) <= 0.001
        }

        private static func sizesEqual(_ lhs: CGSize, _ rhs: CGSize, tolerance: CGFloat) -> Bool {
            abs(lhs.width - rhs.width) <= tolerance &&
                abs(lhs.height - rhs.height) <= tolerance
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

        func displayPixelsMatchAccepted(_ acceptedDisplayPixelSize: CGSize) -> Bool {
            Self.pixelSizesEqual(resolvedGeometry.displayPixelSize, acceptedDisplayPixelSize)
        }

        func startupAcceptanceRejectionReason(
            acceptedContractID: UUID,
            acceptedSceneIdentity: String?
        ) -> String? {
            acceptedGeometryRejectionReason(
                acceptedContractID: acceptedContractID,
                acceptedSceneIdentity: acceptedSceneIdentity
            )
        }

        func acceptedGeometryRejectionReason(
            acceptedContractID: UUID,
            acceptedSceneIdentity: String?
        ) -> String? {
            // A geometry contract proves the response belongs to this request; the host owns the final geometry.
            guard acceptedContractID == contractID else {
                return "geometryContract=\(acceptedContractID.uuidString) expected=\(contractID.uuidString)"
            }
            let normalizedAcceptedSceneIdentity = acceptedSceneIdentity?.isEmpty == false
                ? acceptedSceneIdentity
                : nil
            guard normalizedAcceptedSceneIdentity == sceneIdentity else {
                return "scene=\(normalizedAcceptedSceneIdentity ?? "nil") expected=\(sceneIdentity ?? "nil")"
            }
            return nil
        }

        func isImmediateStartupDowngrade(
            of acceptedTarget: RequestGeometry,
            acceptedDisplayPixelSize: CGSize
        ) -> Bool {
            guard Self.approximatelyEqual(logicalResolution.width, acceptedTarget.logicalResolution.width),
                  Self.approximatelyEqual(logicalResolution.height, acceptedTarget.logicalResolution.height),
                  displayPixelSize.width < acceptedDisplayPixelSize.width - 1 ||
                    displayPixelSize.height < acceptedDisplayPixelSize.height - 1 else {
                return false
            }
            return acceptedTarget.displayPixelsMatchAccepted(acceptedDisplayPixelSize)
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
    var lastSentTransition: ActiveTransition?
    var activeTransition: ActiveTransition?
    @ObservationIgnored var displayResolutionTask: Task<Void, Never>?
    @ObservationIgnored var resizeHoldoffTask: Task<Void, Never>?
    @ObservationIgnored var presentationMaskTimeoutTask: Task<Void, Never>?

    func beginTransition(streamID: StreamID, transitionID: UUID, target: RequestGeometry) {
        let transition = ActiveTransition(streamID: streamID, transitionID: transitionID, target: target)
        activeTransition = transition
        lastSentTransition = transition
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
        let hasQueuedState = latestRequestedTarget != nil ||
            latestRequestedDispatchPolicy != nil ||
            queuedTarget != nil ||
            queuedDispatchPolicy != nil
        guard hasQueuedState else {
            if activeTransition == nil {
                clearLocalPresentationState()
            }
            return
        }
        latestRequestedTarget = nil
        latestRequestedDispatchPolicy = nil
        queuedTarget = nil
        queuedDispatchPolicy = nil
        if activeTransition == nil {
            clearLocalPresentationState()
        }
    }

    func acceptTransition(streamID: StreamID, transitionID: UUID?) -> Bool {
        transitionID != nil &&
            activeTransition?.streamID == streamID &&
            activeTransition?.transitionID == transitionID
    }

    func finishTransition() {
        activeTransition = nil
        lastSentTransition = nil
        if queuedTarget == nil {
            isResizing = false
            maskActive = false
        } else {
            isResizing = true
            maskActive = true
        }
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

    func clearQueuedTargetsMatchingAcceptedDisplayPixels(
        _ acceptedDisplayPixelSize: CGSize
    ) {
        if queuedTarget?.displayPixelsMatchAccepted(acceptedDisplayPixelSize) == true {
            queuedTarget = nil
            queuedDispatchPolicy = nil
        }

        if latestRequestedTarget?.displayPixelsMatchAccepted(acceptedDisplayPixelSize) == true {
            latestRequestedTarget = nil
            latestRequestedDispatchPolicy = nil
        }

        if activeTransition == nil, queuedTarget == nil {
            clearLocalPresentationState()
        }
    }

    func clearLocalPresentationState() {
        guard isResizing || maskActive || presentationMaskTimeoutTask != nil else { return }
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
        let lastSentTargetSnapshot = lastSentTarget
        cancelPendingTasks()
        resizeLifecycleState = preserveLifecycleState ? lifecycleState : .active
        clearLocalPresentationState()
        latestContainerDisplaySize = .zero
        latestDrawableViewSize = .zero
        latestRequestedTarget = nil
        latestRequestedDispatchPolicy = nil
        queuedTarget = nil
        queuedDispatchPolicy = nil
        lastSentTarget = preserveLastSentTarget ? lastSentTargetSnapshot : nil
        lastSentTransition = nil
        activeTransition = nil
    }

    func clearTransientPresentationState(preserveLifecycleState: Bool = false) {
        let lifecycleState = resizeLifecycleState
        cancelPendingTasks()
        resizeLifecycleState = preserveLifecycleState ? lifecycleState : .active
        clearLocalPresentationState()
        latestContainerDisplaySize = .zero
        latestDrawableViewSize = .zero
        latestRequestedTarget = nil
        latestRequestedDispatchPolicy = nil
        queuedTarget = nil
        queuedDispatchPolicy = nil
    }
}
