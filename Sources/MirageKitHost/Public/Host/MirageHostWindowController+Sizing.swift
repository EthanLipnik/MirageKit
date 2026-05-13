//
//  MirageHostWindowController+Sizing.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

import CoreGraphics
import Foundation
import MirageKit

#if os(macOS)
import AppKit
import ApplicationServices

@MainActor
extension MirageHostWindowController {
    /// Returns whether the AX window supports size mutation.
    /// - Parameter axWindow: Accessibility window element.
    func isWindowSizeSettable(_ axWindow: AXUIElement) -> Bool? {
        var isSettable: DarwinBoolean = false
        let result = AXUIElementIsAttributeSettable(axWindow, kAXSizeAttribute as CFString, &isSettable)
        return result == .success ? isSettable.boolValue : nil
    }

    /// Returns the cached minimum size for a window.
    /// - Parameter windowID: Window identifier to query.
    func minimumSize(for windowID: WindowID) -> CGSize? {
        minimumWindowSizes[windowID]
    }

    /// Probes the app's actual minimum size and restores the original frame.
    /// - Parameter window: Window to probe.
    /// - Returns: The discovered minimum size in points, if AX probing succeeded.
    func discoverMinimumSize(for window: MirageWindow) async -> CGSize? {
        if let cached = minimumWindowSizes[window.id] { return cached }
        guard let axWindow = cachedAXWindow(for: window) else { return nil }

        guard isWindowSizeSettable(axWindow) != false else {
            guard let actualFrame = axWindowFrame(axWindow) ?? currentWindowFrame(for: window.id) else { return nil }
            updateMinimumSizeCache(for: window.id, size: actualFrame.size)
            return actualFrame.size
        }

        guard let originalFrame = axWindowFrame(axWindow) ?? currentWindowFrame(for: window.id) else { return nil }
        guard setAXWindowSize(axWindow, CGSize(width: 1, height: 1)) else { return nil }

        do {
            try await Task.sleep(for: .milliseconds(35))
        } catch {
            return nil
        }
        let acceptedFrame = axWindowFrame(axWindow) ?? currentWindowFrame(for: window.id)

        _ = setAXWindowSize(axWindow, originalFrame.size)
        _ = setAXWindowPosition(axWindow, originalFrame.origin)
        hostService?.updateInputCacheFrame(windowID: window.id, newFrame: originalFrame)

        guard let acceptedFrame, acceptedFrame.width > 0, acceptedFrame.height > 0 else { return nil }
        updateMinimumSizeCache(for: window.id, size: acceptedFrame.size)
        return acceptedFrame.size
    }

    /// Updates the cached minimum size for a window and notifies the host.
    /// - Parameters:
    ///   - windowID: Window identifier to update.
    ///   - size: Minimum size in points.
    func updateMinimumSizeCache(for windowID: WindowID, size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        if let existing = minimumWindowSizes[windowID] {
            minimumWindowSizes[windowID] = CGSize(
                width: min(existing.width, size.width),
                height: min(existing.height, size.height)
            )
        } else {
            minimumWindowSizes[windowID] = size
        }

        if let minSize = minimumWindowSizes[windowID] {
            hostService?.updateMinimumSize(for: windowID, minSize: minSize)
        }
    }

    /// Sets the AX size attribute for a window.
    func setAXWindowSize(_ axWindow: AXUIElement, _ size: CGSize) -> Bool {
        var mutableSize = size
        guard let sizeValue = AXValueCreate(.cgSize, &mutableSize) else { return false }
        return AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sizeValue) == .success
    }

    /// Sets the AX position attribute for a window.
    func setAXWindowPosition(_ axWindow: AXUIElement, _ position: CGPoint) -> Bool {
        var mutablePosition = position
        guard let positionValue = AXValueCreate(.cgPoint, &mutablePosition) else { return false }
        return AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, positionValue) == .success
    }

    /// Returns the maximum allowed window size for a streamed window.
    /// - Parameter window: Window to evaluate.
    func maxWindowSize(for window: MirageWindow) -> CGSize? {
        if let virtualBounds = hostService?.virtualDisplayBounds(windowID: window.id) { return virtualBounds.size }

        guard let currentFrame = currentWindowFrame(for: window.id) else { return nil }
        let windowCenter = CGPoint(x: currentFrame.midX, y: currentFrame.midY)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(windowCenter) }) ?? NSScreen.main
        return screen?.visibleFrame.size
    }

    /// Returns the visible frame for sizing a streamed window.
    /// - Parameter window: Window to evaluate.
    func maxWindowSizeRect(for window: MirageWindow) -> CGRect? {
        if let virtualBounds = hostService?.virtualDisplayBounds(windowID: window.id) { return virtualBounds }

        guard let currentFrame = currentWindowFrame(for: window.id) else { return nil }
        let windowCenter = CGPoint(x: currentFrame.midX, y: currentFrame.midY)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(windowCenter) }) ?? NSScreen.main
        return screen?.visibleFrame
    }

    /// Returns the display scale factor for a host window.
    /// - Parameters:
    ///   - window: Window whose containing display should be resolved.
    ///   - fallbackFrame: Frame to use when the latest CGWindowList frame is unavailable.
    func screenScaleFactor(for window: MirageWindow, fallbackFrame: CGRect? = nil) -> CGFloat {
        let referenceFrame = currentWindowFrame(for: window.id) ?? fallbackFrame ?? window.frame
        let windowCenter = CGPoint(x: referenceFrame.midX, y: referenceFrame.midY)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(windowCenter) }) ?? NSScreen.main
        return screen?.backingScaleFactor ?? 2.0
    }

    /// Constrains a size to fit within a given frame while preserving aspect ratio.
    /// - Parameters:
    ///   - size: Size in points to constrain.
    ///   - frame: Bounding frame to fit within.
    func constrainSizeToFrame(_ size: CGSize, frame: CGRect) -> CGSize {
        guard size.width > 0, size.height > 0 else { return size }

        let aspectRatio = size.width / size.height
        var width = size.width
        var height = size.height

        if width > frame.width {
            width = frame.width
            height = width / aspectRatio
        }

        if height > frame.height {
            height = frame.height
            width = height * aspectRatio
        }

        return CGSize(width: width, height: height)
    }

    /// Calculates a window size based on relative scale and aspect ratio.
    /// - Parameters:
    ///   - aspectRatio: Desired aspect ratio for the window.
    ///   - relativeScale: Target scale relative to the visible frame area.
    ///   - visibleFrame: Bounding frame of the target display.
    ///   - minSize: Minimum window size in points.
    func calculateHostWindowSize(
        aspectRatio: CGFloat,
        relativeScale: CGFloat,
        visibleFrame: CGRect,
        minSize: CGSize
    )
    -> CGSize {
        let screenArea = visibleFrame.width * visibleFrame.height
        let targetArea = screenArea * relativeScale

        var width = sqrt(targetArea * aspectRatio)
        var height = sqrt(targetArea / aspectRatio)

        if width < minSize.width {
            width = minSize.width
            height = width / aspectRatio
        }
        if height < minSize.height {
            height = minSize.height
            width = height * aspectRatio
        }

        return constrainSizeToFrame(CGSize(width: width, height: height), frame: visibleFrame)
    }
}
#endif
