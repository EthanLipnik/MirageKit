//
//  MirageHostService+VirtualDisplayPolicies.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

import CoreGraphics
import MirageKit

#if os(macOS)

// MARK: - Virtual Display Support

/// Decision for whether a desktop resize request can be completed without mutating display state.
enum DesktopResizeNoOpDecision: Equatable {
    case noOp
    case nearDuplicateNoOp
    case apply
}

/// Fully resolved geometry for a desktop resize request.
struct DesktopResizeResolvedGeometry: Equatable {
    let logicalResolution: CGSize
    let pixelResolution: CGSize
    let encodedResolution: CGSize
    let requestedDisplayScaleFactor: CGFloat
    let requestedStreamScale: CGFloat
    let encoderMaxWidth: Int?
    let encoderMaxHeight: Int?
    let refreshRate: Int
}

/// Returns whether a desktop resize request already matches display and encoded geometry.
func desktopResizeNoOpDecision(
    currentLogicalResolution: CGSize?,
    currentResolution: CGSize?,
    currentRefreshRate: Int?,
    currentEncodedResolution: CGSize?,
    requestedLogicalResolution: CGSize,
    requestedResolution: CGSize,
    requestedRefreshRate: Int,
    requestedEncodedResolution: CGSize
)
-> DesktopResizeNoOpDecision {
    guard let currentResolution,
          let currentRefreshRate,
          let currentEncodedResolution else { return .apply }
    guard requestedResolution.width > 0, requestedResolution.height > 0 else { return .noOp }
    if currentResolution == requestedResolution,
       currentRefreshRate == requestedRefreshRate,
       currentEncodedResolution == requestedEncodedResolution {
        return .noOp
    }
    if desktopResizeIsNearDuplicateNoOp(
        currentLogicalResolution: currentLogicalResolution,
        currentResolution: currentResolution,
        currentRefreshRate: currentRefreshRate,
        currentEncodedResolution: currentEncodedResolution,
        requestedLogicalResolution: requestedLogicalResolution,
        requestedResolution: requestedResolution,
        requestedRefreshRate: requestedRefreshRate,
        requestedEncodedResolution: requestedEncodedResolution
    ) {
        return .nearDuplicateNoOp
    }
    return .apply
}

private func desktopResizeIsNearDuplicateNoOp(
    currentLogicalResolution: CGSize?,
    currentResolution: CGSize,
    currentRefreshRate: Int,
    currentEncodedResolution: CGSize,
    requestedLogicalResolution: CGSize,
    requestedResolution: CGSize,
    requestedRefreshRate: Int,
    requestedEncodedResolution: CGSize
) -> Bool {
    guard let currentLogicalResolution,
          currentRefreshRate == requestedRefreshRate,
          requestedLogicalResolution.width > 0,
          requestedLogicalResolution.height > 0,
          currentLogicalResolution.width > 0,
          currentLogicalResolution.height > 0,
          virtualDisplayResolutionMatches(
              currentLogicalResolution,
              requestedLogicalResolution,
              tolerance: 2
          ) else {
        return false
    }

    return virtualDisplayResolutionMatches(currentResolution, requestedResolution, tolerance: 16) &&
        virtualDisplayResolutionMatches(currentEncodedResolution, requestedEncodedResolution, tolerance: 16)
}

/// Mirroring strategy to apply while resizing a desktop virtual display.
enum DesktopResizeMirroringPlan: Equatable {
    case suspendAndRestore
    case unchanged
}

/// Returns the mirroring strategy for a desktop stream mode.
func desktopResizeMirroringPlan(for mode: MirageDesktopStreamMode) -> DesktopResizeMirroringPlan {
    if mode == .unified { return .suspendAndRestore }
    return .unchanged
}

/// Returns whether mirroring should be suspended before a desktop resize mutation.
func desktopResizeShouldSuspendMirroring(
    plan: DesktopResizeMirroringPlan,
    updateOutcome: SharedVirtualDisplayManager.DisplayResolutionUpdateOutcome
) -> Bool {
    plan == .suspendAndRestore && updateOutcome != .noChange
}

/// Returns whether stale mirroring state should be cleared after a resize generation change.
func desktopResizeShouldDisableResidualMirroring(
    plan: DesktopResizeMirroringPlan,
    generationChanged: Bool,
    hasResidualMirroringState: Bool
) -> Bool {
    plan == .unchanged && generationChanged && hasResidualMirroringState
}

/// Returns whether rollback must prove mirroring was restored before continuing.
func desktopResizeRequiresMirroringRestoreSuccess(
    desktopStreamMode: MirageDesktopStreamMode
) -> Bool {
    desktopStreamMode == .unified
}

/// Decision for whether a desktop resize transaction still targets an active stream.
enum DesktopResizeTransactionContinuationDecision: Equatable {
    case continueTransaction
    case abortStreamInactive
}

/// Recovery strategy after a desktop resize failure.
enum DesktopResizeFailureRecoveryPlan: Equatable {
    case rollbackToLastKnownGood
    case mainDisplayFallback
    case stopStream
}

/// Returns whether a desktop resize transaction should continue.
func desktopResizeTransactionContinuationDecision(
    requestedStreamID: StreamID,
    activeDesktopStreamID: StreamID?,
    hasDesktopContext: Bool
) -> DesktopResizeTransactionContinuationDecision {
    guard requestedStreamID == activeDesktopStreamID, hasDesktopContext else {
        return .abortStreamInactive
    }
    return .continueTransaction
}

/// Chooses the recovery strategy for a failed desktop resize.
func desktopResizeFailureRecoveryPlan(
    desktopStreamMode: MirageDesktopStreamMode,
    hasPreResizeSnapshot: Bool
) -> DesktopResizeFailureRecoveryPlan {
    if desktopStreamMode == .unified {
        return hasPreResizeSnapshot ? .rollbackToLastKnownGood : .stopStream
    }
    return .mainDisplayFallback
}

/// Pixel resolution produced from a logical desktop size and backing scale.
struct DesktopBackingScaleResolution: Equatable {
    let scaleFactor: CGFloat
    let pixelResolution: CGSize
}

/// Preformatted resize values used in desktop resize logs.
struct DesktopResizeLogContext {
    let transitionIDText: String
    let logicalResolutionText: String
    let pixelResolutionText: String
    let encodedResolutionText: String
}

/// Outcome of desktop resize failure handling.
struct DesktopResizeFailureHandlingResult {
    let completionContext: StreamContext?
    let outcome: MirageDesktopTransitionOutcome
    let shouldStopStreamWithError: Bool
    let shouldRestoreMirroring: Bool
}

/// Resolves display backing scale and pixel size for a logical desktop resolution.
func resolvedDesktopBackingScaleResolution(
    logicalResolution: CGSize,
    defaultScaleFactor: CGFloat
) -> DesktopBackingScaleResolution {
    let geometry = MirageStreamGeometry.resolve(
        logicalSize: logicalResolution,
        displayScaleFactor: defaultScaleFactor
    )

    return DesktopBackingScaleResolution(
        scaleFactor: max(1.0, defaultScaleFactor),
        pixelResolution: geometry.displayPixelSize
    )
}

/// Decision for whether a window resize request can be skipped.
enum WindowResizeNoOpDecision: Equatable {
    case noOp
    case apply
}

/// Compares virtual-display resolutions with tolerance for rounding and mode quantization.
private func virtualDisplayResolutionMatches(
    _ lhs: CGSize,
    _ rhs: CGSize,
    tolerance: CGFloat = 2
) -> Bool {
    abs(lhs.width - rhs.width) <= tolerance &&
        abs(lhs.height - rhs.height) <= tolerance
}

/// Returns whether a window resize request already matches visible and encoded geometry.
func windowResizeNoOpDecision(
    currentVisibleResolution: CGSize?,
    currentDisplayResolution: CGSize?,
    currentEncodedResolution: CGSize?,
    requestedVisibleResolution: CGSize,
    requestedEncodedResolution: CGSize? = nil
)
-> WindowResizeNoOpDecision {
    guard requestedVisibleResolution.width > 0, requestedVisibleResolution.height > 0 else { return .noOp }
    let canonicalRequestedResolution = MirageStreamGeometry.alignedEncodedSize(requestedVisibleResolution)
    let canonicalRequestedEncodedResolution = requestedEncodedResolution.map(MirageStreamGeometry.alignedEncodedSize)
        ?? canonicalRequestedResolution
    if let currentEncodedResolution,
       !virtualDisplayResolutionMatches(currentEncodedResolution, canonicalRequestedEncodedResolution) {
        MirageLogger.host(
            "Window resize no-op rejected due to encoded-size mismatch: encoded=\(currentEncodedResolution), requested=\(canonicalRequestedEncodedResolution)"
        )
        return .apply
    }
    // Prefer the calibrated visible pixel size for no-op decisions.
    // Falling back to display pixels is only safe when visible pixels are unavailable.
    if let currentVisibleResolution {
        if virtualDisplayResolutionMatches(currentVisibleResolution, canonicalRequestedResolution) {
            return .noOp
        }
        return .apply
    }
    if let currentDisplayResolution,
       virtualDisplayResolutionMatches(currentDisplayResolution, canonicalRequestedResolution) {
        return .noOp
    }
    return .apply
}

/// Returns whether a window's placement already matches the requested aspect-fit bounds.
func windowResizePlacementNoOpDecision(
    currentBounds: CGRect?,
    displayVisibleBounds: CGRect?,
    requestedAspectRatio: CGFloat?,
    tolerance: CGFloat = 8
)
-> WindowResizeNoOpDecision {
    guard let currentBounds,
          let displayVisibleBounds,
          currentBounds.width > 0,
          currentBounds.height > 0,
          displayVisibleBounds.width > 0,
          displayVisibleBounds.height > 0,
          let requestedAspectRatio,
          requestedAspectRatio.isFinite,
          requestedAspectRatio > 0 else {
        return .apply
    }

    let requestedBounds = aspectFittedWindowBounds(
        displayVisibleBounds,
        targetAspectRatio: requestedAspectRatio
    )
    if abs(currentBounds.minX - requestedBounds.minX) <= tolerance,
       abs(currentBounds.minY - requestedBounds.minY) <= tolerance,
       abs(currentBounds.width - requestedBounds.width) <= tolerance,
       abs(currentBounds.height - requestedBounds.height) <= tolerance {
        return .noOp
    }

    return .apply
}

/// Combines placement and resolution no-op decisions for a window resize.
func windowResizeCombinedNoOpDecision(
    placementDecision: WindowResizeNoOpDecision,
    resolutionDecision: WindowResizeNoOpDecision
) -> WindowResizeNoOpDecision {
    placementDecision == .noOp && resolutionDecision == .noOp ? .noOp : .apply
}

/// Returns centered bounds that preserve a requested content aspect ratio.
func aspectFittedWindowBounds(
    _ bounds: CGRect,
    targetAspectRatio: CGFloat?
) -> CGRect {
    guard let targetAspectRatio,
          targetAspectRatio.isFinite,
          targetAspectRatio > 0,
          bounds.width > 0,
          bounds.height > 0 else {
        return bounds
    }

    let currentAspect = bounds.width / bounds.height
    guard abs(currentAspect - targetAspectRatio) > 0.0001 else { return bounds }

    var fittedWidth = bounds.width
    var fittedHeight = bounds.height
    if currentAspect > targetAspectRatio {
        fittedWidth = floor(bounds.height * targetAspectRatio)
    } else {
        fittedHeight = floor(bounds.width / targetAspectRatio)
    }

    fittedWidth = max(1, fittedWidth)
    fittedHeight = max(1, fittedHeight)
    let originX = bounds.minX + (bounds.width - fittedWidth) * 0.5
    let originY = bounds.minY + (bounds.height - fittedHeight) * 0.5
    return CGRect(x: originX, y: originY, width: fittedWidth, height: fittedHeight)
}

/// Resolves the target content aspect ratio for a virtual-display-backed window.
func resolvedWindowTargetContentAspectRatio(
    existingAspectRatio: CGFloat?,
    overrideAspectRatio: CGFloat?
) -> CGFloat? {
    if let overrideAspectRatio,
       overrideAspectRatio.isFinite,
       overrideAspectRatio > 0 {
        return overrideAspectRatio
    }

    if let existingAspectRatio,
       existingAspectRatio.isFinite,
       existingAspectRatio > 0 {
        return existingAspectRatio
    }

    return nil
}

/// Resolves the aspect ratio to use for an app stream resize request.
func resolvedAppStreamResizeAspectRatio(
    existingAspectRatio: CGFloat?,
    requestedLogicalResolution: CGSize
) -> CGFloat? {
    if requestedLogicalResolution.width > 0,
       requestedLogicalResolution.height > 0 {
        let requestedAspectRatio = requestedLogicalResolution.width / requestedLogicalResolution.height
        if requestedAspectRatio.isFinite, requestedAspectRatio > 0 {
            return requestedAspectRatio
        }
    }

    if let existingAspectRatio,
       existingAspectRatio.isFinite,
       existingAspectRatio > 0 {
        return existingAspectRatio
    }

    return nil
}

/// Error used to abort a desktop resize when its stream has gone away.
enum DesktopResizeTransactionAbort: Error {
    case streamNoLongerActive
}

#endif
