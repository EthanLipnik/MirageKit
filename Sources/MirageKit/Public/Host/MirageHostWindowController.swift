//
//  MirageHostWindowController.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/21/26.
//

import Foundation
import CoreGraphics

#if os(macOS)
import AppKit
import ApplicationServices

/// Manages window operations via Accessibility API for Mirage hosts.
@MainActor
public final class MirageHostWindowController {
    // MARK: - Dependencies

    /// Reference to host service for virtual display queries.
    public weak var hostService: MirageHostService?

    // MARK: - AX Window Cache

    /// Cached AXUIElement references for windows.
    private var cachedAXWindows: [WindowID: AXUIElement] = [:]

    /// Minimum window sizes per window.
    private var minimumWindowSizes: [WindowID: CGSize] = [:]

    // MARK: - Timers

    /// Timer for periodically re-centering streamed windows.
    private var windowCenteringTimer: Timer?

    /// Pending resize request for debouncing.
    private var pendingResizeRequest: (windowID: WindowID, width: Int, height: Int)?

    /// Timer for debouncing resize updates.
    private var resizeDebounceTimer: DispatchSourceTimer?

    /// Debounce interval for resize events (ms).
    private let resizeDebounceIntervalMs: UInt64 = 150

    /// Creates a window controller with an optional host service reference.
    public init(hostService: MirageHostService? = nil) {
        self.hostService = hostService
    }

    // MARK: - Window Centering Timer

    /// Starts periodic re-centering for active streamed windows.
    public func startWindowCenteringTimer() {
        windowCenteringTimer?.invalidate()
        windowCenteringTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.recenterAllStreamedWindows()
            }
        }
    }

    /// Stops periodic re-centering for streamed windows.
    public func stopWindowCenteringTimer() {
        windowCenteringTimer?.invalidate()
        windowCenteringTimer = nil
    }

    private func recenterAllStreamedWindows() {
        guard let sessions = hostService?.activeStreams else { return }
        for session in sessions {
            let window = session.window
            guard let axWindow = getOrCacheAXWindow(for: window),
                  let frame = axWindowFrame(axWindow) else { continue }
            centerWindowOnScreen(axWindow, newSize: frame.size, windowID: window.id)
        }
    }

    // MARK: - AX Window Caching

    /// Returns a cached AX window element or looks it up if needed.
    public func getOrCacheAXWindow(for window: MirageWindow) -> AXUIElement? {
        if let cached = cachedAXWindows[window.id] {
            return cached
        }

        guard let axWindow = findAXWindow(for: window) else {
            return nil
        }

        cachedAXWindows[window.id] = axWindow
        return axWindow
    }

    /// Removes a cached AX window for the provided window ID.
    public func invalidateCache(for windowID: WindowID) {
        cachedAXWindows.removeValue(forKey: windowID)
    }

    private func findAXWindow(for window: MirageWindow) -> AXUIElement? {
        guard let app = window.application else { return nil }

        guard NSRunningApplication(processIdentifier: app.id) != nil else {
            cachedAXWindows.removeValue(forKey: window.id)
            return nil
        }

        let appElement = AXUIElementCreateApplication(app.id)

        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)

        guard result == .success, let axWindows = windowsRef as? [AXUIElement] else {
            return nil
        }

        if axWindows.count == 1 {
            return axWindows[0]
        }

        guard let windowList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]],
              let windowInfo = windowList.first(where: { ($0[kCGWindowNumber as String] as? Int) == Int(window.id) }),
              let bounds = windowInfo[kCGWindowBounds as String] as? [String: CGFloat],
              let windowX = bounds["X"],
              let windowY = bounds["Y"] else {
            return axWindows.first
        }

        for axWindow in axWindows {
            var positionRef: CFTypeRef?
            AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &positionRef)

            if let positionValue = positionRef {
                var position = CGPoint.zero
                AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)

                if abs(position.x - windowX) < 10 && abs(position.y - windowY) < 10 {
                    return axWindow
                }
            }
        }

        return axWindows.first
    }

    // MARK: - Window Frame Helpers

    /// Returns the current CGWindowList frame for a window ID.
    public func currentWindowFrame(for windowID: WindowID) -> CGRect? {
        if let windowList = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
           let windowInfo = windowList.first,
           let bounds = windowInfo[kCGWindowBounds as String] as? [String: CGFloat],
           let x = bounds["X"], let y = bounds["Y"],
           let w = bounds["Width"], let h = bounds["Height"] {
            return CGRect(x: x, y: y, width: w, height: h)
        }
        return nil
    }

    /// Returns the AX frame for a window element if available.
    public func axWindowFrame(_ axWindow: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef, let sizeRef,
              CFGetTypeID(positionRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else {
            return nil
        }

        return CGRect(origin: position, size: size)
    }

    // MARK: - Window Sizing

    /// Returns the maximum allowed window size for a streamed window.
    /// - Parameter window: Window to evaluate.
    public func maxWindowSize(for window: MirageWindow) -> CGSize? {
        if let virtualBounds = hostService?.getVirtualDisplayBounds(windowID: window.id) {
            return virtualBounds.size
        }

        guard let currentFrame = currentWindowFrame(for: window.id) else { return nil }
        let windowCenter = CGPoint(x: currentFrame.midX, y: currentFrame.midY)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(windowCenter) }) ?? NSScreen.main
        return screen?.visibleFrame.size
    }

    /// Returns the visible frame for sizing a streamed window.
    /// - Parameter window: Window to evaluate.
    public func maxWindowSizeRect(for window: MirageWindow) -> CGRect? {
        if let virtualBounds = hostService?.getVirtualDisplayBounds(windowID: window.id) {
            return virtualBounds
        }

        guard let currentFrame = currentWindowFrame(for: window.id) else { return nil }
        let windowCenter = CGPoint(x: currentFrame.midX, y: currentFrame.midY)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(windowCenter) }) ?? NSScreen.main
        return screen?.visibleFrame
    }

    /// Returns whether the AX window supports size mutation.
    /// - Parameter axWindow: Accessibility window element.
    public func isWindowSizeSettable(_ axWindow: AXUIElement) -> Bool? {
        var isSettable: DarwinBoolean = false
        let result = AXUIElementIsAttributeSettable(axWindow, kAXSizeAttribute as CFString, &isSettable)
        return result == .success ? isSettable.boolValue : nil
    }

    /// Returns the cached minimum size for a window.
    /// - Parameter windowID: Window identifier to query.
    public func getMinimumSize(for windowID: WindowID) -> CGSize? {
        minimumWindowSizes[windowID]
    }

    /// Updates the cached minimum size for a window and notifies the host.
    /// - Parameters:
    ///   - windowID: Window identifier to update.
    ///   - size: Minimum size in points.
    public func updateMinimumSizeCache(for windowID: WindowID, size: CGSize) {
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

    // MARK: - Window Centering

    /// Centers a window on its display and updates the input cache.
    /// - Parameters:
    ///   - axWindow: Accessibility window element.
    ///   - newSize: Target size in points.
    ///   - windowID: Optional window identifier for cache updates.
    public func centerWindowOnScreen(_ axWindow: AXUIElement, newSize: CGSize, windowID: WindowID? = nil) {
        guard let currentFrame = axWindowFrame(axWindow) else { return }

        let screenFrame: CGRect
        let isVirtualDisplay: Bool

        if let wid = windowID, let virtualBounds = hostService?.getVirtualDisplayBounds(windowID: wid) {
            screenFrame = virtualBounds
            isVirtualDisplay = true
        } else {
            let windowCenter = CGPoint(x: currentFrame.midX, y: currentFrame.midY)
            let screen = NSScreen.screens.first(where: { $0.frame.contains(windowCenter) }) ?? NSScreen.main
            guard let screen else { return }
            screenFrame = screen.visibleFrame
            isVirtualDisplay = false
        }

        let centeredX = screenFrame.origin.x + (screenFrame.width - newSize.width) / 2

        let axCenteredY: CGFloat
        if isVirtualDisplay {
            axCenteredY = screenFrame.origin.y + (screenFrame.height - newSize.height) / 2
        } else {
            let cocoaCenteredY = screenFrame.origin.y + (screenFrame.height - newSize.height) / 2
            axCenteredY = cocoaYToAXY(cocoaCenteredY, windowHeight: newSize.height)
        }

        var newPosition = CGPoint(x: centeredX, y: axCenteredY)
        guard let positionValue = AXValueCreate(.cgPoint, &newPosition) else { return }

        let result = AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, positionValue)
        if result == .success, let wid = windowID {
            if let actualFrame = axWindowFrame(axWindow) {
                hostService?.updateInputCacheFrame(windowID: wid, newFrame: actualFrame)
            } else {
                let newFrame = CGRect(origin: newPosition, size: newSize)
                hostService?.updateInputCacheFrame(windowID: wid, newFrame: newFrame)
            }
        }
    }

    /// Convert Cocoa Y coordinate (bottom-left origin) to AX Y coordinate (top-left origin).
    private func cocoaYToAXY(_ cocoaY: CGFloat, windowHeight: CGFloat) -> CGFloat {
        let totalHeight = NSScreen.screens.map { $0.frame.maxY }.max() ?? NSScreen.main?.frame.height ?? 1080
        return totalHeight - cocoaY - windowHeight
    }

    // MARK: - Window Resizing

    /// Resizes and centers a streamed window using Accessibility APIs.
    /// - Parameters:
    ///   - window: Window to resize.
    ///   - targetSize: Desired size in points.
    public func resizeAndCenterWindowForStream(_ window: MirageWindow, targetSize: CGSize) {
        guard let axWindow = getOrCacheAXWindow(for: window) else { return }

        let screenFrame: CGRect
        let isVirtualDisplay: Bool
        if let virtualBounds = hostService?.getVirtualDisplayBounds(windowID: window.id) {
            screenFrame = virtualBounds
            isVirtualDisplay = true
        } else {
            guard let screen = NSScreen.main else { return }
            screenFrame = screen.visibleFrame
            isVirtualDisplay = false
        }

        var newSize = targetSize
        newSize.width = min(newSize.width, screenFrame.width)
        newSize.height = min(newSize.height, screenFrame.height)

        let centeredX = screenFrame.origin.x + (screenFrame.width - newSize.width) / 2

        let axCenteredY: CGFloat
        if isVirtualDisplay {
            axCenteredY = screenFrame.origin.y + (screenFrame.height - newSize.height) / 2
        } else {
            let cocoaCenteredY = screenFrame.origin.y + (screenFrame.height - newSize.height) / 2
            axCenteredY = cocoaYToAXY(cocoaCenteredY, windowHeight: newSize.height)
        }

        var newPosition = CGPoint(x: centeredX, y: axCenteredY)

        guard let sizeValue = AXValueCreate(.cgSize, &newSize) else { return }

        let setResult = AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sizeValue)

        if setResult == .success {
            guard let positionValue = AXValueCreate(.cgPoint, &newPosition) else { return }
            let posResult = AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, positionValue)
            if posResult == .success {
                if let actualFrame = axWindowFrame(axWindow) {
                    hostService?.updateInputCacheFrame(windowID: window.id, newFrame: actualFrame)
                } else {
                    let newFrame = CGRect(origin: newPosition, size: newSize)
                    hostService?.updateInputCacheFrame(windowID: window.id, newFrame: newFrame)
                }
            }
        }
    }

    /// Debounces capture resolution updates for a window.
    /// - Parameters:
    ///   - windowID: Window identifier to update.
    ///   - width: Target pixel width.
    ///   - height: Target pixel height.
    public func scheduleResizeUpdate(windowID: WindowID, width: Int, height: Int) {
        pendingResizeRequest = (windowID, width, height)

        resizeDebounceTimer?.cancel()

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(Int(resizeDebounceIntervalMs)))
        timer.setEventHandler { [weak self] in
            guard let self, let request = self.pendingResizeRequest else { return }
            self.pendingResizeRequest = nil

            Task {
                await self.hostService?.updateCaptureResolution(
                    for: request.windowID,
                    width: request.width,
                    height: request.height
                )
            }
        }
        timer.resume()
        resizeDebounceTimer = timer
    }

    // MARK: - Helper Methods

    /// Constrains a size to fit within a given frame while preserving aspect ratio.
    /// - Parameters:
    ///   - size: Size in points to constrain.
    ///   - frame: Bounding frame to fit within.
    public func constrainSizeToFrame(_ size: CGSize, frame: CGRect) -> CGSize {
        guard size.width > 0 && size.height > 0 else { return size }

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
    public func calculateHostWindowSize(
        aspectRatio: CGFloat,
        relativeScale: CGFloat,
        visibleFrame: CGRect,
        minSize: CGSize
    ) -> CGSize {
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
