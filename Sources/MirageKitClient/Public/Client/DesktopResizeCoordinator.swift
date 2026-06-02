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

        private var resolvedGeometry: MirageStreamGeometry {
            MirageStreamGeometry.resolve(
                logicalSize: logicalResolution,
                displayScaleFactor: displayScaleFactor,
                requestedStreamScale: requestedStreamScale,
                encoderMaxWidth: encoderMaxWidth,
                encoderMaxHeight: encoderMaxHeight,
                disableResolutionCap: disableResolutionCap
            )
        }

        private var contract: DesktopGeometryContract {
            DesktopGeometryContract(
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
            acceptedSceneIdentity: String?,
            acceptedLogicalResolution: CGSize,
            acceptedDisplayPixelSize: CGSize?,
            acceptedEncodedPixelSize: CGSize?,
            acceptedDisplayScaleFactor: CGFloat?,
            acceptedRefreshTargetHz: Int?
        ) -> String? {
            acceptedGeometryRejectionReason(
                acceptedContractID: acceptedContractID,
                acceptedSceneIdentity: acceptedSceneIdentity,
                acceptedLogicalResolution: acceptedLogicalResolution,
                acceptedDisplayPixelSize: acceptedDisplayPixelSize,
                acceptedEncodedPixelSize: acceptedEncodedPixelSize,
                acceptedDisplayScaleFactor: acceptedDisplayScaleFactor,
                acceptedRefreshTargetHz: acceptedRefreshTargetHz
            )
        }

        func legacyStartupAcceptanceRejectionReason(
            acceptedLogicalResolution: CGSize,
            acceptedDisplayPixelSize: CGSize,
            acceptedDisplayScaleFactor: CGFloat?,
            acceptedRefreshTargetHz: Int?
        ) -> String? {
            guard Self.approximatelyEqual(logicalResolution.width, acceptedLogicalResolution.width),
                  Self.approximatelyEqual(logicalResolution.height, acceptedLogicalResolution.height) else {
                return "logical=\(Int(acceptedLogicalResolution.width))x\(Int(acceptedLogicalResolution.height)) " +
                    "expected=\(Int(logicalResolution.width))x\(Int(logicalResolution.height))"
            }
            if let acceptedDisplayScaleFactor,
               !Self.approximatelyEqual(displayScaleFactor, acceptedDisplayScaleFactor) {
                return "scale=\(String(format: "%.3f", acceptedDisplayScaleFactor)) " +
                    "expected=\(String(format: "%.3f", displayScaleFactor))"
            }
            guard Self.pixelSizesEqual(resolvedGeometry.displayPixelSize, acceptedDisplayPixelSize) else {
                return "displayPixels=\(Int(acceptedDisplayPixelSize.width))x\(Int(acceptedDisplayPixelSize.height)) " +
                    "expected=\(Int(resolvedGeometry.displayPixelSize.width))x\(Int(resolvedGeometry.displayPixelSize.height))"
            }
            if let refreshTargetHz, let acceptedRefreshTargetHz {
                guard acceptedRefreshTargetHz == refreshTargetHz else {
                    return "refresh=\(acceptedRefreshTargetHz) expected=\(refreshTargetHz)"
                }
            }
            return nil
        }

        func acceptedGeometryRejectionReason(
            acceptedContractID: UUID,
            acceptedSceneIdentity: String?,
            acceptedLogicalResolution: CGSize,
            acceptedDisplayPixelSize: CGSize?,
            acceptedEncodedPixelSize: CGSize?,
            acceptedDisplayScaleFactor: CGFloat?,
            acceptedRefreshTargetHz: Int?
        ) -> String? {
            guard acceptedContractID == contractID else {
                return "geometryContract=\(acceptedContractID.uuidString) expected=\(contractID.uuidString)"
            }
            let normalizedAcceptedSceneIdentity = acceptedSceneIdentity?.isEmpty == false
                ? acceptedSceneIdentity
                : nil
            guard normalizedAcceptedSceneIdentity == sceneIdentity else {
                return "scene=\(normalizedAcceptedSceneIdentity ?? "nil") expected=\(sceneIdentity ?? "nil")"
            }
            guard Self.approximatelyEqual(logicalResolution.width, acceptedLogicalResolution.width),
                  Self.approximatelyEqual(logicalResolution.height, acceptedLogicalResolution.height) else {
                return "logical=\(Int(acceptedLogicalResolution.width))x\(Int(acceptedLogicalResolution.height)) " +
                    "expected=\(Int(logicalResolution.width))x\(Int(logicalResolution.height))"
            }
            guard let acceptedDisplayScaleFactor,
                  Self.approximatelyEqual(displayScaleFactor, acceptedDisplayScaleFactor) else {
                let acceptedScaleText = acceptedDisplayScaleFactor.map { String(format: "%.3f", $0) } ?? "nil"
                return "scale=\(acceptedScaleText) expected=\(String(format: "%.3f", displayScaleFactor))"
            }
            guard let acceptedDisplayPixelSize else {
                return "displayPixels=nil expected=\(Int(resolvedGeometry.displayPixelSize.width))x\(Int(resolvedGeometry.displayPixelSize.height))"
            }
            guard Self.pixelSizesEqual(resolvedGeometry.displayPixelSize, acceptedDisplayPixelSize) else {
                return "displayPixels=\(Int(acceptedDisplayPixelSize.width))x\(Int(acceptedDisplayPixelSize.height)) " +
                    "expected=\(Int(resolvedGeometry.displayPixelSize.width))x\(Int(resolvedGeometry.displayPixelSize.height))"
            }
            guard let acceptedEncodedPixelSize else {
                return "encodedPixels=nil expected=\(Int(resolvedGeometry.encodedPixelSize.width))x\(Int(resolvedGeometry.encodedPixelSize.height))"
            }
            guard Self.pixelSizesEqual(resolvedGeometry.encodedPixelSize, acceptedEncodedPixelSize) else {
                return "encodedPixels=\(Int(acceptedEncodedPixelSize.width))x\(Int(acceptedEncodedPixelSize.height)) " +
                    "expected=\(Int(resolvedGeometry.encodedPixelSize.width))x\(Int(resolvedGeometry.encodedPixelSize.height))"
            }
            if let refreshTargetHz {
                guard acceptedRefreshTargetHz == refreshTargetHz else {
                    return "refresh=\(acceptedRefreshTargetHz.map(String.init) ?? "nil") expected=\(refreshTargetHz)"
                }
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
    var activeTransition: ActiveTransition?
    @ObservationIgnored var displayResolutionTask: Task<Void, Never>?
    @ObservationIgnored var resizeHoldoffTask: Task<Void, Never>?
    @ObservationIgnored var presentationMaskTimeoutTask: Task<Void, Never>?

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
        transitionID != nil &&
            activeTransition?.streamID == streamID &&
            activeTransition?.transitionID == transitionID
    }

    func finishTransition() {
        activeTransition = nil
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
        activeTransition = nil
    }
}
