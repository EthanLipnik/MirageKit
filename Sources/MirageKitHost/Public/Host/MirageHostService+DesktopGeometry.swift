//
//  MirageHostService+DesktopGeometry.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
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

#if os(macOS)
import AppKit

@MainActor
extension MirageHostService {
    /// Interval for keeping the display awake and cursor centered during virtual-display setup.
    private static let virtualDisplaySetupGuardKeepaliveInterval: Duration = .milliseconds(350)

    /// Delay before one final cursor recenter and power-assertion release after setup settles.
    private static let virtualDisplaySetupGuardCompletionDelay: Duration = .milliseconds(250)

    /// Resolve input bounds for desktop streaming based on physical display size.
    /// When mirroring a virtual display with a different aspect ratio, the mirrored
    /// content is aspect-fit within the physical display and input should target
    /// that content rect (not the full physical bounds).
    func resolvedDesktopInputBounds(
        physicalBounds: CGRect,
        virtualResolution: CGSize?
    )
    -> CGRect {
        if desktopStreamMode == .secondary, let bounds = resolveDesktopDisplayBounds() { return bounds }
        return Self.resolvedMirroredDesktopInputBounds(
            physicalBounds: physicalBounds,
            virtualResolution: virtualResolution
        )
    }

    nonisolated static func resolvedMirroredDesktopInputBounds(
        physicalBounds: CGRect,
        virtualResolution: CGSize?
    )
    -> CGRect {
        guard let virtualResolution,
              virtualResolution.width > 0,
              virtualResolution.height > 0 else {
            return physicalBounds
        }

        let contentAspect = virtualResolution.width / virtualResolution.height
        let boundsAspect = physicalBounds.width / physicalBounds.height
        var fittedSize = physicalBounds.size

        if boundsAspect > contentAspect {
            fittedSize.height = physicalBounds.height
            fittedSize.width = fittedSize.height * contentAspect
        } else {
            fittedSize.width = physicalBounds.width
            fittedSize.height = fittedSize.width / contentAspect
        }

        return CGRect(
            x: physicalBounds.minX + (physicalBounds.width - fittedSize.width) * 0.5,
            y: physicalBounds.minY + (physicalBounds.height - fittedSize.height) * 0.5,
            width: fittedSize.width,
            height: fittedSize.height
        )
    }

    nonisolated static func cocoaRect(fromCGDisplayRect cgRect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(
            x: cgRect.origin.x,
            y: primaryHeight - cgRect.origin.y - cgRect.height,
            width: cgRect.width,
            height: cgRect.height
        )
    }

    nonisolated static func resolvedMirroredDesktopCursorMonitorBounds(
        physicalBounds: CGRect,
        virtualResolution: CGSize?,
        primaryHeight: CGFloat
    )
    -> CGRect {
        cocoaRect(
            fromCGDisplayRect: resolvedMirroredDesktopInputBounds(
                physicalBounds: physicalBounds,
                virtualResolution: virtualResolution
            ),
            primaryHeight: primaryHeight
        )
    }

    /// State for the temporary wake/cursor keepalive around virtual-display setup.
    struct VirtualDisplaySetupGuardState {
        let token: UUID
        let periodicTask: Task<Void, Never>
        /// Cursor point captured before display mirroring mutates display bounds.
        let cursorAnchorPoint: CGPoint?
    }

    /// Resolves usable visible bounds for the primary physical display.
    func resolvedPrimaryPhysicalDisplayVisibleBounds() -> CGRect? {
        let displayID = desktopPrimaryPhysicalDisplayID ?? resolvePrimaryPhysicalDisplayID() ?? CGMainDisplayID()
        let fullBounds = CGDisplayBounds(displayID)
        guard fullBounds.width > 0, fullBounds.height > 0 else { return nil }

        desktopPrimaryPhysicalDisplayID = displayID
        desktopPrimaryPhysicalBounds = fullBounds

        var visibleBounds = platformVirtualDisplayBackend.displayVisibleBounds(
            displayID,
            knownBounds: fullBounds
        )
        visibleBounds = visibleBounds.intersection(fullBounds)
        if visibleBounds.isEmpty {
            visibleBounds = fullBounds
        }
        return visibleBounds
    }

    /// Resolves the cursor point used during virtual-display setup.
    nonisolated static func resolvedVirtualDisplaySetupCursorPoint(
        cursorAnchorPoint: CGPoint?,
        visibleBounds: CGRect?
    )
    -> CGPoint? {
        if let cursorAnchorPoint { return cursorAnchorPoint }
        guard let visibleBounds,
              visibleBounds.width > 0,
              visibleBounds.height > 0 else {
            return nil
        }
        return CGPoint(x: visibleBounds.midX, y: visibleBounds.midY)
    }

    /// Warps the cursor to a stable primary-display point during setup.
    func centerCursorOnPrimaryPhysicalDisplay(
        reason: String,
        cursorAnchorPoint: CGPoint? = nil
    )
    -> CGPoint? {
        let visibleBounds = cursorAnchorPoint == nil ? resolvedPrimaryPhysicalDisplayVisibleBounds() : nil
        guard let point = Self.resolvedVirtualDisplaySetupCursorPoint(
            cursorAnchorPoint: cursorAnchorPoint,
            visibleBounds: visibleBounds
        ) else {
            return nil
        }
        let source = cursorAnchorPoint == nil ? "live" : "anchor"
        CGWarpMouseCursorPosition(point)
        MirageLogger.host(
            "Virtual display setup cursor centered reason=\(reason) x=\(Int(point.x.rounded())) y=\(Int(point.y.rounded())) source=\(source)"
        )
        return point
    }

    /// Wakes the display and centers the cursor for virtual-display setup.
    func performVirtualDisplaySetupWakeAndCenter(
        reason: String,
        cursorAnchorPoint: CGPoint? = nil
    )
    -> CGPoint? {
        PowerAssertionManager.wakeDisplay()
        return centerCursorOnPrimaryPhysicalDisplay(
            reason: reason,
            cursorAnchorPoint: cursorAnchorPoint
        )
    }

    /// Best-effort wake and cursor-center helper for setup keepalives.
    func wakeAndCenterVirtualDisplaySetupCursor(
        reason: String,
        cursorAnchorPoint: CGPoint? = nil
    ) {
        _ = performVirtualDisplaySetupWakeAndCenter(
            reason: reason,
            cursorAnchorPoint: cursorAnchorPoint
        )
    }

    /// Starts a temporary guard that keeps the display awake and cursor positioned during setup.
    func beginVirtualDisplaySetupGuard(reason: String) async -> UUID {
        if let existing = activeVirtualDisplaySetupGuard {
            await cancelVirtualDisplaySetupGuard(existing.token, reason: "superseded:\(reason)")
        }

        await PowerAssertionManager.shared.enable()
        let cursorAnchorPoint = performVirtualDisplaySetupWakeAndCenter(reason: "\(reason):begin")

        let token = UUID()
        let periodicTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.virtualDisplaySetupGuardKeepaliveInterval)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                guard let self else { return }
                wakeAndCenterVirtualDisplaySetupCursor(
                    reason: "\(reason):keepalive",
                    cursorAnchorPoint: activeVirtualDisplaySetupGuard?.cursorAnchorPoint
                )
            }
        }

        activeVirtualDisplaySetupGuard = VirtualDisplaySetupGuardState(
            token: token,
            periodicTask: periodicTask,
            cursorAnchorPoint: cursorAnchorPoint
        )
        MirageLogger.host("Virtual display setup guard started reason=\(reason) token=\(token.uuidString)")
        return token
    }

    /// Completes and releases a virtual-display setup guard.
    func completeVirtualDisplaySetupGuard(
        _ token: UUID?,
        reason: String
    ) async {
        guard let token,
              let activeGuard = activeVirtualDisplaySetupGuard,
              activeGuard.token == token else {
            return
        }

        let cursorAnchorPoint = activeGuard.cursorAnchorPoint
        activeGuard.periodicTask.cancel()
        activeVirtualDisplaySetupGuard = nil
        wakeAndCenterVirtualDisplaySetupCursor(
            reason: "\(reason):settled",
            cursorAnchorPoint: cursorAnchorPoint
        )
        MirageLogger.host("Virtual display setup guard completed reason=\(reason) token=\(token.uuidString)")

        Task { @MainActor [weak self, cursorAnchorPoint] in
            do {
                try await Task.sleep(for: Self.virtualDisplaySetupGuardCompletionDelay)
            } catch {
                await PowerAssertionManager.shared.disable()
                return
            }

            if self?.activeVirtualDisplaySetupGuard == nil {
                self?.wakeAndCenterVirtualDisplaySetupCursor(
                    reason: "\(reason):delayed",
                    cursorAnchorPoint: cursorAnchorPoint
                )
            }
            await PowerAssertionManager.shared.disable()
        }
    }

    /// Cancels and releases a virtual-display setup guard.
    func cancelVirtualDisplaySetupGuard(
        _ token: UUID?,
        reason: String
    ) async {
        guard let token,
              let activeGuard = activeVirtualDisplaySetupGuard,
              activeGuard.token == token else {
            return
        }

        activeGuard.periodicTask.cancel()
        activeVirtualDisplaySetupGuard = nil
        await PowerAssertionManager.shared.disable()
        MirageLogger.host("Virtual display setup guard cancelled reason=\(reason) token=\(token.uuidString)")
    }

    /// Resolve the current virtual display bounds for secondary desktop streaming.
    /// Uses CoreGraphics coordinates for input injection.
    func resolveDesktopDisplayBounds() -> CGRect? {
        guard let displayID = desktopVirtualDisplayID else {
            return resolvedDesktopDisplayBounds(
                cachedBounds: desktopDisplayBounds,
                liveBounds: nil,
                displayModeSize: nil,
                displayOrigin: desktopDisplayBounds?.origin ?? .zero
            )
        }

        let bounds = platformVirtualDisplayBackend.displayBounds(displayID)
        let displayModeSize = platformVirtualDisplayBackend.currentDisplayModeSizes(displayID)?.logical
        let resolvedBounds = resolvedDesktopDisplayBounds(
            cachedBounds: desktopDisplayBounds,
            liveBounds: bounds,
            displayModeSize: displayModeSize,
            displayOrigin: bounds.origin
        )
        if let resolvedBounds { desktopDisplayBounds = resolvedBounds }
        return resolvedBounds
    }

    /// Resolve the current virtual display bounds for cursor monitoring (Cocoa coordinates).
    func resolveDesktopDisplayBoundsForCursorMonitor() -> CGRect? {
        let resolvedBounds: CGRect?
        if let displayID = desktopVirtualDisplayID,
           let screen = NSScreen.screens.first(where: {
               ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
            }) {
            resolvedBounds = screen.frame
        } else if let displayID = desktopVirtualDisplayID {
            let cgBounds = platformVirtualDisplayBackend.displayBounds(displayID)
            let primaryDisplayHeight = CGDisplayBounds(CGMainDisplayID()).height
            resolvedBounds = resolvedDesktopDisplayBounds(
                cachedBounds: desktopDisplayBounds,
                liveBounds: cgBounds,
                displayModeSize: nil,
                displayOrigin: cgBounds.origin
            ).map { Self.cocoaRect(fromCGDisplayRect: $0, primaryHeight: primaryDisplayHeight) }
        } else {
            let primaryDisplayHeight = CGDisplayBounds(CGMainDisplayID()).height
            resolvedBounds = resolvedDesktopDisplayBounds(
                cachedBounds: desktopDisplayBounds,
                liveBounds: nil,
                displayModeSize: nil,
                displayOrigin: desktopDisplayBounds?.origin ?? .zero
            ).map { Self.cocoaRect(fromCGDisplayRect: $0, primaryHeight: primaryDisplayHeight) }
        }

        if let bounds = resolvedBounds {
            lastResolvedCursorMonitorBounds = bounds
            return bounds
        }
        return lastResolvedCursorMonitorBounds
    }

    /// Resolves primary physical display identity and bounds from cached and live candidates.
    nonisolated static func resolvedDesktopPrimaryPhysicalDisplaySnapshot(
        cachedDisplayID: CGDirectDisplayID?,
        cachedBounds: CGRect?,
        resolvedPrimaryDisplayID: CGDirectDisplayID?,
        mainDisplayID: CGDirectDisplayID,
        boundsProvider: (CGDirectDisplayID) -> CGRect
    ) -> (displayID: CGDirectDisplayID, bounds: CGRect?) {
        var candidateDisplayIDs: [CGDirectDisplayID] = []

        func appendCandidate(_ displayID: CGDirectDisplayID?) {
            guard let displayID else { return }
            guard !candidateDisplayIDs.contains(displayID) else { return }
            candidateDisplayIDs.append(displayID)
        }

        appendCandidate(cachedDisplayID)
        appendCandidate(resolvedPrimaryDisplayID)
        appendCandidate(mainDisplayID)

        for displayID in candidateDisplayIDs {
            let bounds = boundsProvider(displayID)
            if bounds.width > 0, bounds.height > 0 {
                return (displayID, bounds)
            }
        }

        let fallbackBounds: CGRect? = if let cachedBounds,
                                         cachedBounds.width > 0,
                                         cachedBounds.height > 0 {
            cachedBounds
        } else {
            nil
        }

        return (candidateDisplayIDs.first ?? mainDisplayID, fallbackBounds)
    }

    /// Refresh cached physical display bounds after mirroring changes.
    /// Returns the updated physical bounds.
    func refreshDesktopPrimaryPhysicalBounds() -> CGRect {
        let snapshot = Self.resolvedDesktopPrimaryPhysicalDisplaySnapshot(
            cachedDisplayID: desktopPrimaryPhysicalDisplayID,
            cachedBounds: desktopPrimaryPhysicalBounds,
            resolvedPrimaryDisplayID: resolvePrimaryPhysicalDisplayID(),
            mainDisplayID: CGMainDisplayID(),
            boundsProvider: { platformVirtualDisplayBackend.displayBounds($0) }
        )
        desktopPrimaryPhysicalDisplayID = snapshot.displayID
        if let bounds = snapshot.bounds {
            desktopPrimaryPhysicalBounds = bounds
            return bounds
        }
        return desktopPrimaryPhysicalBounds ?? .zero
    }
}

#endif
