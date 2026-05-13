//
//  MirageHostService+VirtualDisplayPlacement.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

import CoreGraphics
import Foundation
import MirageKit

#if os(macOS)
@MainActor
extension MirageHostService {
    /// Returns why a virtual-display-backed window has drifted from its expected space or frame.
    func virtualDisplayPlacementDriftReason(
        windowID: WindowID,
        expectedSpaceID: CGSSpaceID,
        state: WindowVirtualDisplayState
    ) -> String? {
        let currentSpaceMembership = CGSWindowSpaceBridge.spaces(for: windowID)
        if !currentSpaceMembership.isEmpty, !currentSpaceMembership.contains(expectedSpaceID) {
            return "space drift expected=\(expectedSpaceID) actual=\(currentSpaceMembership)"
        }

        guard let currentFrame = currentWindowFrame(for: windowID) else { return nil }

        let expectedFrame = aspectFittedWindowBounds(
            state.bounds,
            targetAspectRatio: state.targetContentAspectRatio
        )
        if Self.windowFrameMatchesExpectedPlacement(
            currentFrame: currentFrame,
            expectedFrame: expectedFrame,
            currentSpaceMembership: currentSpaceMembership,
            expectedSpaceID: expectedSpaceID
        ) {
            return nil
        }

        return "frame drift expected=\(expectedFrame) observed=\(currentFrame)"
    }

    /// Returns whether a window frame still matches its expected virtual-display placement.
    nonisolated static func windowFrameMatchesExpectedPlacement(
        currentFrame: CGRect,
        expectedFrame: CGRect,
        currentSpaceMembership: [CGSSpaceID],
        expectedSpaceID: CGSSpaceID,
        originTolerance: CGFloat = 8,
        sizeTolerance: CGFloat = 8
    ) -> Bool {
        let originMatches = abs(currentFrame.minX - expectedFrame.minX) <= originTolerance &&
            abs(currentFrame.minY - expectedFrame.minY) <= originTolerance
        let sizeMatches = abs(currentFrame.width - expectedFrame.width) <= sizeTolerance &&
            abs(currentFrame.height - expectedFrame.height) <= sizeTolerance
        if originMatches, sizeMatches {
            return true
        }

        let intersectsExpected = currentFrame.intersects(
            expectedFrame.insetBy(dx: -originTolerance, dy: -originTolerance)
        )
        let minimumExpectedWidth = max(1, expectedFrame.width - sizeTolerance)
        let minimumExpectedHeight = max(1, expectedFrame.height - sizeTolerance)
        let maximumExpectedWidth = expectedFrame.width + sizeTolerance
        let maximumExpectedHeight = expectedFrame.height + sizeTolerance
        let sizeWithinExpectedRange = currentFrame.width >= minimumExpectedWidth &&
            currentFrame.height >= minimumExpectedHeight &&
            currentFrame.width <= maximumExpectedWidth &&
            currentFrame.height <= maximumExpectedHeight
        if intersectsExpected, sizeWithinExpectedRange {
            return true
        }

        if currentSpaceMembership.contains(expectedSpaceID) {
            let localExpected = CGRect(origin: .zero, size: expectedFrame.size)
                .insetBy(dx: -originTolerance, dy: -originTolerance)
            if currentFrame.intersects(localExpected), sizeWithinExpectedRange {
                return true
            }
        }

        return false
    }

    /// Repairs app-window placement on its virtual display after host activation.
    func enforceVirtualDisplayPlacementAfterActivation(
        windowID: WindowID,
        force: Bool = false
    ) async -> Bool {
        if shouldSkipPlacementRepair(for: windowID) {
            lastWindowPlacementRepairAtByWindowID.removeValue(forKey: windowID)
            return false
        }

        // After startup we never resize app-stream windows again here.
        // Maintenance only recenters the current frame and refreshes the display crop.
        for (_, context) in streamsByID {
            let wID = await context.windowID
            guard wID == windowID else { continue }
            let mode = await context.captureMode
            if mode == .window {
                lastWindowPlacementRepairAtByWindowID.removeValue(forKey: windowID)
                return false
            }
            break
        }

        guard let state = virtualDisplayState(windowID: windowID) else { return false }

        let placementBounds = state.bounds

        let resolvedSpaceID = CGVirtualDisplayBridge.space(for: state.displayID)
        guard resolvedSpaceID != 0 else {
            MirageLogger.host("Skipping placement reassert for window \(windowID): no active space for display \(state.displayID)")
            return false
        }

        let driftReason = force
            ? "forced reassert"
            : virtualDisplayPlacementDriftReason(
                windowID: windowID,
                expectedSpaceID: resolvedSpaceID,
                state: state
            )
        guard let driftReason else { return false }

        let now = CFAbsoluteTimeGetCurrent()
        let cooldown: CFAbsoluteTime = 0.20
        if !force,
           let lastAppliedAt = lastWindowPlacementRepairAtByWindowID[windowID],
           now - lastAppliedAt < cooldown {
            return false
        }
        lastWindowPlacementRepairAtByWindowID[windowID] = now

        CGSWindowSpaceBridge.moveWindowToSpace(windowID, spaceID: resolvedSpaceID)
        let centeringBounds = state.displayVisibleBounds.width > 0 && state.displayVisibleBounds.height > 0
            ? state.displayVisibleBounds
            : placementBounds
        await WindowSpaceManager.shared.centerWindow(windowID, on: centeringBounds)
        do {
            try await Task.sleep(for: .milliseconds(force ? 40 : 20))
        } catch {
            return false
        }

        let refreshedFrame = currentWindowFrame(for: windowID) ?? placementBounds
        inputStreamCache.updateWindowFrame(state.streamID, newFrame: refreshedFrame)
        MirageLogger.host(
            "Recentered virtual-display placement for window \(windowID) on display \(state.displayID) without resizing (\(driftReason))"
        )
        await refreshSharedDisplayAppCaptureStateBestEffort(
            streamID: state.streamID,
            reason: force ? "forced placement reassert" : "placement repair"
        )
        return true
    }

    /// Returns whether placement repair should be skipped for a window being replaced.
    func shouldSkipPlacementRepair(for windowID: WindowID) -> Bool {
        pendingAppWindowReplacementsByStreamID.values.contains { replacement in
            replacement.closedWindowID == windowID
        }
    }
}
#endif
