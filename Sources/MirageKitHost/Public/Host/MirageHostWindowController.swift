//
//  MirageHostWindowController.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/21/26.
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
import ApplicationServices

/// Manages window operations via Accessibility API for Mirage hosts.
@MainActor
public final class MirageHostWindowController {
    /// Delay between follow-up Accessibility frame enforcement attempts.
    private static let windowFrameEnforcementInterval: TimeInterval = 0.12

    /// Pixel tolerance used to avoid chasing insignificant window-size drift.
    private static let windowSizeEnforcementTolerance: CGFloat = 2.0

    /// Debounce interval for host resize notifications in milliseconds.
    private static let resizeDebounceIntervalMs: UInt64 = 150

    // MARK: - Dependencies

    /// Host service used to inspect active streams and virtual-display placement.
    public weak var hostService: MirageHostService?

    // MARK: - AX Window Cache

    /// Accessibility elements cached by CGWindowID to avoid repeated AX window-list scans.
    var cachedAXWindows: [WindowID: AXUIElement] = [:]

    /// Minimum accepted window sizes learned from temporary AX resize probes.
    var minimumWindowSizes: [WindowID: CGSize] = [:]

    /// Cached CGWindowList frames keyed by window ID.
    var cachedWindowFrames: [WindowID: CGRect] = [:]

    // MARK: - Timers

    /// A scheduled frame enforcement pass and its remaining retry budget.
    private struct FrameEnforcementRequest {
        /// Size the streamed window should retain on the host display.
        let targetSize: CGSize
        /// Number of follow-up attempts before the controller stops chasing drift.
        let remainingAttempts: Int
    }

    /// Pending follow-up enforcement for windows that drifted after an AX mutation.
    private var pendingFrameEnforcementByWindowID: [WindowID: FrameEnforcementRequest] = [:]

    /// One-shot enforcement tasks keyed by streamed window ID.
    private var frameEnforcementTasksByWindowID: [WindowID: Task<Void, Never>] = [:]

    /// Whether direct-stream frame enforcement is active.
    private var frameEnforcementEnabled = false

    /// Maximum number of follow-up enforcement attempts after a resize.
    private let maxFrameEnforcementAttempts = 20

    /// Pending resize requests keyed by window for debouncing.
    private var pendingResizeRequestsByWindowID: [WindowID: (width: Int, height: Int)] = [:]

    /// Timers for debouncing resize updates keyed by window.
    private var resizeDebounceTimersByWindowID: [WindowID: DispatchSourceTimer] = [:]

    /// Creates a window controller with an optional host service reference.
    public init(hostService: MirageHostService? = nil) {
        self.hostService = hostService
    }

    // MARK: - Window Centering Timer

    /// Starts periodic re-centering for active streamed windows.
    public func startWindowCenteringTimer() {
        frameEnforcementEnabled = true
        recenterAllStreamedWindows()
    }

    /// Stops periodic re-centering for streamed windows.
    public func stopWindowCenteringTimer() {
        frameEnforcementEnabled = false
        pendingFrameEnforcementByWindowID.removeAll()
        for task in frameEnforcementTasksByWindowID.values {
            task.cancel()
        }
        frameEnforcementTasksByWindowID.removeAll()
        for timer in resizeDebounceTimersByWindowID.values {
            timer.cancel()
        }
        resizeDebounceTimersByWindowID.removeAll()
        pendingResizeRequestsByWindowID.removeAll()
    }

    /// Requests frame enforcement for every currently streamed window.
    private func recenterAllStreamedWindows() {
        guard let sessions = hostService?.activeStreams else { return }
        for session in sessions {
            requestFrameEnforcement(for: session.window)
        }
    }

    /// Applies one Accessibility size/position enforcement pass for a directly streamed window.
    ///
    /// - Returns: `true` when meaningful drift remains and a follow-up pass should be scheduled.
    private func enforceDirectStreamWindowFrame(
        axWindow: AXUIElement,
        window: MirageMedia.MirageWindow,
        desiredSizeOverride: CGSize? = nil
    ) -> Bool {
        let currentFrame = axWindowFrame(axWindow) ?? currentWindowFrame(for: window.id)
        let fallbackSize = currentFrame?.size ?? window.frame.size
        let desiredSize = CGSize(
            width: max(1, desiredSizeOverride?.width ?? window.frame.width),
            height: max(1, desiredSizeOverride?.height ?? window.frame.height)
        )
        var enforcedSize = desiredSize
        if let visibleFrame = maxWindowSizeRect(for: window) {
            enforcedSize = constrainSizeToFrame(enforcedSize, frame: visibleFrame)
        }

        let hasMeaningfulSizeDrift = abs(fallbackSize.width - enforcedSize.width) > Self.windowSizeEnforcementTolerance ||
            abs(fallbackSize.height - enforcedSize.height) > Self.windowSizeEnforcementTolerance
        if hasMeaningfulSizeDrift {
            var mutableSize = enforcedSize
            if let sizeValue = AXValueCreate(.cgSize, &mutableSize) {
                let setResult = AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sizeValue)
                if setResult != .success {
                    return false
                }
            }
        }

        let targetFrame = centerWindowOnScreen(
            axWindow,
            newSize: enforcedSize,
            windowID: window.id,
            scheduleFollowUp: false
        )
        guard let finalFrame = axWindowFrame(axWindow) ?? currentWindowFrame(for: window.id) else {
            return false
        }
        let remainingWidthDrift = abs(finalFrame.width - enforcedSize.width)
        let remainingHeightDrift = abs(finalFrame.height - enforcedSize.height)
        let remainingXDrift = targetFrame.map { abs(finalFrame.origin.x - $0.origin.x) } ?? 0
        let remainingYDrift = targetFrame.map { abs(finalFrame.origin.y - $0.origin.y) } ?? 0
        return remainingWidthDrift > Self.windowSizeEnforcementTolerance ||
            remainingHeightDrift > Self.windowSizeEnforcementTolerance ||
            remainingXDrift > Self.windowSizeEnforcementTolerance ||
            remainingYDrift > Self.windowSizeEnforcementTolerance
    }

    func requestFrameEnforcement(
        for window: MirageMedia.MirageWindow,
        targetSize: CGSize? = nil,
        remainingAttempts: Int? = nil
    ) {
        guard frameEnforcementEnabled else { return }
        guard hostService?.isStreamUsingVirtualDisplay(windowID: window.id) != true else { return }

        let attempts = max(1, remainingAttempts ?? maxFrameEnforcementAttempts)
        let target = CGSize(
            width: max(1, targetSize?.width ?? window.frame.width),
            height: max(1, targetSize?.height ?? window.frame.height)
        )
        pendingFrameEnforcementByWindowID[window.id] = FrameEnforcementRequest(
            targetSize: target,
            remainingAttempts: attempts
        )
        frameEnforcementTasksByWindowID[window.id]?.cancel()
        frameEnforcementTasksByWindowID[window.id] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    for: .milliseconds(Int(Self.windowFrameEnforcementInterval * 1000))
                )
            } catch {
                return
            }
            self?.performFrameEnforcement(windowID: window.id)
        }
    }

    private func performFrameEnforcement(windowID: WindowID) {
        guard frameEnforcementEnabled else { return }
        guard let session = hostService?.activeStreams.first(where: { $0.window.id == windowID }) else {
            pendingFrameEnforcementByWindowID.removeValue(forKey: windowID)
            frameEnforcementTasksByWindowID.removeValue(forKey: windowID)
            return
        }
        guard let request = pendingFrameEnforcementByWindowID[windowID] else { return }
        guard let axWindow = cachedAXWindow(for: session.window) else {
            pendingFrameEnforcementByWindowID.removeValue(forKey: windowID)
            frameEnforcementTasksByWindowID.removeValue(forKey: windowID)
            return
        }

        let needsFollowUp = enforceDirectStreamWindowFrame(
            axWindow: axWindow,
            window: session.window,
            desiredSizeOverride: request.targetSize
        )
        if needsFollowUp, request.remainingAttempts > 1 {
            requestFrameEnforcement(
                for: session.window,
                targetSize: request.targetSize,
                remainingAttempts: request.remainingAttempts - 1
            )
            return
        }

        pendingFrameEnforcementByWindowID.removeValue(forKey: windowID)
        frameEnforcementTasksByWindowID.removeValue(forKey: windowID)
    }

    // MARK: - Window Centering

    /// Centers a window on its display and updates the input cache.
    /// - Parameters:
    ///   - axWindow: Accessibility window element.
    ///   - newSize: Target size in points.
    ///   - windowID: Optional window identifier for cache updates.
    func centerWindowOnScreen(
        _ axWindow: AXUIElement,
        newSize: CGSize,
        windowID: WindowID? = nil,
        scheduleFollowUp: Bool = true
    ) -> CGRect? {
        guard let currentFrame = axWindowFrame(axWindow) else { return nil }

        let screenFrame: CGRect
        let isVirtualDisplay: Bool

        if let wid = windowID, let virtualBounds = hostService?.virtualDisplayBounds(windowID: wid) {
            screenFrame = virtualBounds
            isVirtualDisplay = true
        } else {
            let windowCenter = CGPoint(x: currentFrame.midX, y: currentFrame.midY)
            let screen = NSScreen.screens.first(where: { $0.frame.contains(windowCenter) }) ?? NSScreen.main
            guard let screen else { return nil }
            screenFrame = screen.visibleFrame
            isVirtualDisplay = false
        }

        let centeredX = screenFrame.origin.x + (screenFrame.width - newSize.width) / 2

        let axCenteredY: CGFloat
        if isVirtualDisplay { axCenteredY = screenFrame.origin.y + (screenFrame.height - newSize.height) / 2 } else {
            let cocoaCenteredY = screenFrame.origin.y + (screenFrame.height - newSize.height) / 2
            axCenteredY = cocoaYToAXY(cocoaCenteredY, windowHeight: newSize.height)
        }

        var newPosition = CGPoint(x: centeredX, y: axCenteredY)
        let targetFrame = CGRect(origin: newPosition, size: newSize)
        guard let positionValue = AXValueCreate(.cgPoint, &newPosition) else { return nil }

        let result = AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, positionValue)
        if result == .success, let wid = windowID {
            if let actualFrame = axWindowFrame(axWindow) { hostService?.updateInputCacheFrame(windowID: wid, newFrame: actualFrame) } else {
                let newFrame = CGRect(origin: newPosition, size: newSize)
                hostService?.updateInputCacheFrame(windowID: wid, newFrame: newFrame)
            }
            if scheduleFollowUp,
               let session = hostService?.activeStreams.first(where: { $0.window.id == wid }) {
                requestFrameEnforcement(for: session.window, targetSize: newSize)
            }
        }
        guard result == .success else { return targetFrame }
        return targetFrame
    }

    /// Convert Cocoa Y coordinate (bottom-left origin) to AX Y coordinate (top-left origin).
    private func cocoaYToAXY(_ cocoaY: CGFloat, windowHeight: CGFloat) -> CGFloat {
        let totalHeight = NSScreen.screens.map(\.frame.maxY).max() ?? NSScreen.main?.frame.height ?? 1080
        return totalHeight - cocoaY - windowHeight
    }

    // MARK: - Window Resizing

    /// Resizes and centers a streamed window using Accessibility APIs.
    /// - Parameters:
    ///   - window: Window to resize.
    ///   - targetSize: Desired size in points.
    func resizeAndCenterWindowForStream(_ window: MirageMedia.MirageWindow, targetSize: CGSize) {
        guard let axWindow = cachedAXWindow(for: window) else { return }

        let screenFrame: CGRect
        let isVirtualDisplay: Bool
        if let virtualBounds = hostService?.virtualDisplayBounds(windowID: window.id) {
            screenFrame = virtualBounds
            isVirtualDisplay = true
        } else {
            let referenceFrame = currentWindowFrame(for: window.id) ?? window.frame
            let windowCenter = CGPoint(x: referenceFrame.midX, y: referenceFrame.midY)
            guard let screen = NSScreen.screens.first(where: { $0.frame.contains(windowCenter) }) ?? NSScreen.main else {
                return
            }
            screenFrame = screen.visibleFrame
            isVirtualDisplay = false
        }

        var newSize = targetSize
        newSize.width = min(newSize.width, screenFrame.width)
        newSize.height = min(newSize.height, screenFrame.height)

        let centeredX = screenFrame.origin.x + (screenFrame.width - newSize.width) / 2

        let axCenteredY: CGFloat
        if isVirtualDisplay { axCenteredY = screenFrame.origin.y + (screenFrame.height - newSize.height) / 2 } else {
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
                if let actualFrame = axWindowFrame(axWindow) { hostService?.updateInputCacheFrame(windowID: window.id, newFrame: actualFrame) } else {
                    let newFrame = CGRect(origin: newPosition, size: newSize)
                    hostService?.updateInputCacheFrame(windowID: window.id, newFrame: newFrame)
                }
                requestFrameEnforcement(for: window, targetSize: newSize)
            }
        }
    }

    /// Debounces capture resolution updates for a window.
    /// - Parameters:
    ///   - windowID: Window identifier to update.
    ///   - width: Target pixel width.
    ///   - height: Target pixel height.
    func scheduleResizeUpdate(windowID: WindowID, width: Int, height: Int) {
        pendingResizeRequestsByWindowID[windowID] = (width, height)
        resizeDebounceTimersByWindowID[windowID]?.cancel()

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(Int(Self.resizeDebounceIntervalMs)))
        timer.setEventHandler { [weak self] in
            guard let self,
                  let request = pendingResizeRequestsByWindowID.removeValue(forKey: windowID) else {
                return
            }
            resizeDebounceTimersByWindowID.removeValue(forKey: windowID)

            Task {
                await self.hostService?.updateCaptureResolution(
                    for: windowID,
                    width: request.width,
                    height: request.height
                )
            }
        }
        timer.resume()
        resizeDebounceTimersByWindowID[windowID] = timer
    }

}
#endif
