//
//  CGVirtualDisplayBridge+Utilities.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Virtual display utility helpers.
//

import MirageKit
#if os(macOS)
import AppKit
import CoreGraphics
import Foundation

extension CGVirtualDisplayBridge {
    // MARK: - Display Utilities

    struct DisplayModeSizes: Sendable {
        let logical: CGSize
        let pixel: CGSize
    }

    private static func sizeMatches(_ observed: CGSize, expected: CGSize, tolerance: CGFloat = 1.0) -> Bool {
        guard expected.width > 0, expected.height > 0 else { return false }
        let widthDelta = abs(observed.width - expected.width)
        let heightDelta = abs(observed.height - expected.height)
        return widthDelta <= tolerance && heightDelta <= tolerance
    }

    static func currentDisplayModeSizes(_ displayID: CGDirectDisplayID) -> DisplayModeSizes? {
        guard let mode = CGDisplayCopyDisplayMode(displayID) else { return nil }
        let logical = CGSize(width: CGFloat(mode.width), height: CGFloat(mode.height))
        let pixel = CGSize(width: CGFloat(mode.pixelWidth), height: CGFloat(mode.pixelHeight))
        return DisplayModeSizes(logical: logical, pixel: pixel)
    }

    /// Returns CoreGraphics' current bounds for a display.
    /// `CGDisplayBounds` can return stale values for newly created virtual displays;
    /// prefer a known virtual-display resolution when one is available.
    static func displayBounds(_ displayID: CGDirectDisplayID) -> CGRect {
        CGDisplayBounds(displayID)
    }

    /// Wait for a virtual display to become online with non-zero bounds.
    /// Returns the observed bounds when ready, or nil on timeout.
    static func waitForDisplayReady(
        _ displayID: CGDirectDisplayID,
        expectedResolution: CGSize,
        alternateExpectedResolution: CGSize = .zero,
        timeout: TimeInterval = 4.0,
        pollInterval: TimeInterval = 0.05,
        startupBudget: DesktopVirtualDisplayStartupBudget? = nil
    )
    async -> CGRect? {
        let resolvedTimeout = startupBudget?.boundedTimeout(timeout) ?? timeout
        let deadline = Date().addingTimeInterval(resolvedTimeout)
        let earlyExitDeadline = Date().addingTimeInterval(min(1.0, resolvedTimeout))
        var lastBounds = CGRect.zero
        var everOnline = false

        while Date() < deadline {
            if startupBudget?.isExpired == true { break }
            let online = isDisplayOnline(displayID)
            let bounds = CGDisplayBounds(displayID)
            lastBounds = bounds
            if online { everOnline = true }

            // Early exit: if the display has never come online after 1s,
            // it likely won't — skip to the next creation attempt.
            if !everOnline, Date() >= earlyExitDeadline {
                MirageLogger.host(
                    "Display \(displayID) not online after 1s; skipping to next attempt"
                )
                return nil
            }

            if online, bounds.width > 0, bounds.height > 0 {
                if expectedResolution.width > 0, expectedResolution.height > 0 {
                    let expectedPixel = alternateExpectedResolution.width > 0 && alternateExpectedResolution.height > 0
                        ? alternateExpectedResolution
                        : expectedResolution

                    if let modeSizes = currentDisplayModeSizes(displayID),
                       sizeMatches(modeSizes.logical, expected: expectedResolution),
                       sizeMatches(modeSizes.pixel, expected: expectedPixel) {
                        let origin = configuredDisplayOrigins[displayID] ?? bounds.origin
                        return CGRect(origin: origin, size: expectedResolution)
                    }

                    if sizeMatches(bounds.size, expected: expectedResolution) {
                        let origin = configuredDisplayOrigins[displayID] ?? bounds.origin
                        return CGRect(origin: origin, size: expectedResolution)
                    }
                } else {
                    return bounds
                }
            }

            let sleepMs = Int(max(10.0, pollInterval * 1000.0))
            let boundedSleepMs = startupBudget?.boundedDelayMilliseconds(sleepMs) ?? sleepMs
            do {
                try await Task.sleep(for: .milliseconds(boundedSleepMs))
            } catch {
                return nil
            }
        }

        let online = isDisplayOnline(displayID)
        if online, expectedResolution.width > 0, expectedResolution.height > 0 {
            let origin = configuredDisplayOrigins[displayID] ?? lastBounds.origin
            let fallbackBounds = CGRect(origin: origin, size: expectedResolution)
            MirageLogger
                .host(
                    "Display \(displayID) online but bounds invalid after wait; using known resolution \(fallbackBounds)"
                )
            return fallbackBounds
        }

        let timeoutText = timeout.formatted(.number.precision(.fractionLength(2)))
        MirageLogger.error(
            .host,
            "Display \(displayID) not ready after \(timeoutText)s (online: \(online), lastBounds: \(lastBounds))"
        )
        return nil
    }

    /// Returns display bounds using a known size when CoreGraphics has not caught up.
    /// `CGDisplayBounds` can return stale origin and size values immediately after
    /// virtual-display creation.
    ///
    /// For window centering purposes, the virtual display is treated as starting at (0, 0).
    /// This is the coordinate space where windows will be positioned.
    static func displayBounds(_ displayID: CGDirectDisplayID, knownResolution: CGSize) -> CGRect {
        // CGDisplayBounds is unreliable for newly created virtual displays, especially size.
        // If we have non-zero bounds, trust the reported size (points) to keep windows on-screen.
        let rawBounds = CGDisplayBounds(displayID)
        let configuredOrigin = configuredDisplayOrigins[displayID]
        let fallbackOrigin = configuredOrigin ?? rawBounds.origin
        let originDriftTolerance: CGFloat = 24

        if rawBounds.width > 0, rawBounds.height > 0 {
            let widthDelta = abs(rawBounds.width - knownResolution.width)
            let heightDelta = abs(rawBounds.height - knownResolution.height)
            if widthDelta <= 1, heightDelta <= 1 {
                if let configuredOrigin {
                    let originDeltaX = abs(rawBounds.origin.x - configuredOrigin.x)
                    let originDeltaY = abs(rawBounds.origin.y - configuredOrigin.y)
                    if originDeltaX > originDriftTolerance || originDeltaY > originDriftTolerance {
                        configuredDisplayOrigins[displayID] = rawBounds.origin
                        MirageLogger.host(
                            "displayBounds(\(displayID)): configured origin \(configuredOrigin) diverged from raw origin \(rawBounds.origin); adopting raw origin"
                        )
                    }
                }
                return rawBounds
            }
            if let modeSizes = currentDisplayModeSizes(displayID),
               sizeMatches(modeSizes.logical, expected: rawBounds.size),
               !sizeMatches(modeSizes.logical, expected: knownResolution) {
                let rawBackedBounds = rawBounds
                MirageLogger
                    .host(
                        "displayBounds(\(displayID)): raw size \(rawBounds.size) differs from knownResolution \(knownResolution), modeLogical=\(modeSizes.logical), modePixel=\(modeSizes.pixel); preferring mode-backed raw bounds \(rawBackedBounds)"
                    )
                return rawBackedBounds
            }
            MirageLogger
                .host(
                    "displayBounds(\(displayID)): raw size \(rawBounds.size) differs from knownResolution \(knownResolution) (fallbackOrigin \(fallbackOrigin))"
                )
        }

        // Fallback to known resolution when raw bounds are not available yet.
        let bounds = CGRect(origin: fallbackOrigin, size: knownResolution)
        MirageLogger
            .host(
                "displayBounds(\(displayID)): using origin \(fallbackOrigin) with knownSize=\(knownResolution) (rawBounds=\(rawBounds)) -> \(bounds)"
            )
        return bounds
    }

    private static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return CGDirectDisplayID(number.uint32Value) == displayID
        }
    }

    private static func normalizedVisibleInsets(
        displayID: CGDirectDisplayID,
        screenFrame: CGRect,
        visibleFrame: CGRect
    )
    -> (left: CGFloat, right: CGFloat, top: CGFloat, bottom: CGFloat) {
        var left = max(0, visibleFrame.minX - screenFrame.minX)
        var right = max(0, screenFrame.maxX - visibleFrame.maxX)
        var top = max(0, screenFrame.maxY - visibleFrame.maxY)
        var bottom = max(0, visibleFrame.minY - screenFrame.minY)

        // Guard against coordinate-space drift where frame and visibleFrame origins
        // disagree for virtual displays. Trust visible size first, then distribute.
        let expectedHorizontal = max(0, screenFrame.width - visibleFrame.width)
        let expectedVertical = max(0, screenFrame.height - visibleFrame.height)
        let tolerance: CGFloat = 1

        let rawHorizontal = left + right
        if abs(rawHorizontal - expectedHorizontal) > tolerance {
            if expectedHorizontal <= tolerance {
                left = 0
                right = 0
            } else {
                left = min(max(0, left), expectedHorizontal)
                right = max(0, expectedHorizontal - left)
            }
            MirageLogger.host(
                "Normalized visibleFrame horizontal insets for display \(displayID): raw=\(rawHorizontal), expected=\(expectedHorizontal)"
            )
        }

        let rawVertical = top + bottom
        if abs(rawVertical - expectedVertical) > tolerance {
            if expectedVertical <= tolerance {
                top = 0
                bottom = 0
            } else {
                top = min(max(0, top), expectedVertical)
                bottom = max(0, expectedVertical - top)
            }
            MirageLogger.host(
                "Normalized visibleFrame vertical insets for display \(displayID): raw=\(rawVertical), expected=\(expectedVertical)"
            )
        }

        return (left: left, right: right, top: top, bottom: bottom)
    }

    /// Returns the display visible bounds in global points (excluding dock/menu bar).
    /// Falls back to full display bounds when no screen match is available.
    static func displayVisibleBounds(
        _ displayID: CGDirectDisplayID,
        knownBounds: CGRect? = nil
    )
    -> CGRect {
        let resolvedBounds = knownBounds ?? displayBounds(displayID)
        guard let screen = screen(for: displayID) else { return resolvedBounds }

        let screenFrame = screen.frame
        let visible = screen.visibleFrame
        guard visible.width > 0, visible.height > 0, screenFrame.width > 0, screenFrame.height > 0 else {
            return resolvedBounds
        }

        // NSScreen frame coordinates do not align with CGDisplayBounds/AX global coordinates.
        // Derive insets from NSScreen in its own coordinate space, then project those
        // insets onto the resolved display bounds used by capture/input/window placement.
        let insets = normalizedVisibleInsets(
            displayID: displayID,
            screenFrame: screenFrame,
            visibleFrame: visible
        )
        let leftInset = insets.left
        let rightInset = insets.right
        let topInset = insets.top
        let bottomInset = insets.bottom

        let width = max(1, resolvedBounds.width - leftInset - rightInset)
        let height = max(1, resolvedBounds.height - topInset - bottomInset)

        return CGRect(
            x: resolvedBounds.minX + leftInset,
            y: resolvedBounds.minY + topInset,
            width: width,
            height: height
        )
    }

    /// Build a display-capture source rect in display-local logical points.
    static func displayCaptureSourceRect(
        _ displayID: CGDirectDisplayID,
        knownBounds: CGRect? = nil
    )
    -> CGRect {
        let fullBounds = knownBounds ?? displayBounds(displayID)
        let visibleBounds = displayVisibleBounds(displayID, knownBounds: fullBounds)
        let clippedVisible = visibleBounds.intersection(fullBounds)
        guard !clippedVisible.isEmpty else { return .zero }
        // sourceRect uses display-local points in the same top-left-oriented
        // coordinate space as our mapped visible bounds.
        let localX = clippedVisible.minX - fullBounds.minX
        let localY = clippedVisible.minY - fullBounds.minY
        return CGRect(
            x: max(0, localX),
            y: max(0, localY),
            width: clippedVisible.width,
            height: clippedVisible.height
        )
    }

    /// Attempt to reclaim an orphaned virtual display.  The display was
    /// already invalidated in a previous session but the OS hadn't finished
    /// removing it.  We clear our tracking and let the next creation proceed
    /// with a fresh display ID.
    static func forceInvalidateOrphan(_ displayID: CGDirectDisplayID) {
        configuredDisplayOrigins.removeValue(forKey: displayID)
        if isDisplayOnline(displayID) {
            MirageLogger.host("Orphaned display \(displayID) still online; will create a new display ID")
        } else {
            MirageLogger.host("Orphaned display \(displayID) already reclaimed by OS")
        }
    }

    static func isDisplayOnline(_ displayID: CGDirectDisplayID) -> Bool {
        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &displayCount)
        guard displayCount > 0 else { return false }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetOnlineDisplayList(displayCount, &displays, &displayCount)
        return displays.contains(displayID)
    }

    /// Returns true if the display is a Mirage-created virtual display.
    static func isMirageDisplay(_ displayID: CGDirectDisplayID) -> Bool {
        CGDisplayVendorNumber(displayID) == mirageVendorID &&
            CGDisplayModelNumber(displayID) == mirageProductID
    }

    /// Returns true if an online Mirage display already uses the given serial number.
    /// Used to skip stale persistent serials that map to orphaned virtual displays.
    static func isMirageSerialOnline(_ serial: UInt32) -> Bool {
        guard serial != 0 else { return false }
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(UInt32(displayIDs.count), &displayIDs, &count)
        for i in 0 ..< Int(count) {
            let id = displayIDs[i]
            guard isMirageDisplay(id) else { continue }
            if CGDisplaySerialNumber(id) == serial { return true }
        }
        return false
    }

    /// Returns the current Mission Control space ID for a display.
    static func space(for displayID: CGDirectDisplayID) -> CGSSpaceID {
        CGSWindowSpaceBridge.currentSpace(for: displayID)
    }
}
#endif
