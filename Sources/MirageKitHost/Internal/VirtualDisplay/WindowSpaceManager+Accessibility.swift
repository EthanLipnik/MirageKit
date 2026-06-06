//
//  WindowSpaceManager+Accessibility.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/10/26.
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
import ApplicationServices

struct WindowAccessibilityResizeResult: Sendable {
    let outcome: MirageWire.MirageAppWindowResizeResultOutcome
    let observedFrame: CGRect?
    let reason: String
}

extension WindowSpaceManager {
    /// Brings the window to the foreground using CGS first, then Accessibility as a fallback.
    func raiseWindow(_ windowID: WindowID, axWindow: AXUIElement?) -> Bool {
        let didRaiseWithCGS = CGSWindowSpaceBridge.bringWindowToFront(windowID)
        if didRaiseWithCGS {
            return true
        }
        guard let axWindow else { return false }
        return AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString) == .success
    }

    /// Resolves the Accessibility window element that corresponds to a compositor window ID.
    func resolveAXWindow(for windowID: WindowID) -> AXUIElement? {
        guard let windowInfo = windowInfo(for: windowID) else { return nil }
        guard let ownerPID = windowInfo.ownerPID else { return nil }

        let appElement = AXUIElementCreateApplication(ownerPID)
        let axWindows = HostAccessibilityWindowLookup.windows(in: appElement)
        guard !axWindows.isEmpty else { return nil }

        if axWindows.count == 1 {
            return axWindows.first
        }

        // Prefer exact window-ID matching so traffic-light changes and size/position writes
        // target the streamed window even when an app has multiple similarly sized windows.
        if let axWindow = HostAccessibilityWindowLookup.window(matching: windowID, in: axWindows) {
            return axWindow
        }

        let targetFrame = windowInfo.frame
        for axWindow in axWindows {
            guard let frame = axWindowFrame(axWindow) else { continue }
            if abs(frame.origin.x - targetFrame.origin.x) <= 24,
               abs(frame.origin.y - targetFrame.origin.y) <= 24,
               abs(frame.size.width - targetFrame.size.width) <= 24,
               abs(frame.size.height - targetFrame.size.height) <= 24 {
                return axWindow
            }
        }

        return axWindows.first
    }

    /// Reads a window frame through Accessibility position and size attributes.
    func axWindowFrame(_ axWindow: AXUIElement) -> CGRect? {
        HostAccessibilityWindowLookup.frame(of: axWindow)
    }

    /// Returns the best available frame for a window, preferring Accessibility when available.
    func resolvedWindowFrame(_ windowID: WindowID, axWindow: AXUIElement?) -> CGRect? {
        axWindow.flatMap(axWindowFrame) ?? windowInfo(for: windowID)?.frame
    }

    /// Checks whether an Accessibility attribute can be written on the supplied element.
    func isAXAttributeSettable(_ element: AXUIElement, attribute: CFString) -> Bool {
        var isSettable: DarwinBoolean = false
        let result = AXUIElementIsAttributeSettable(element, attribute, &isSettable)
        return result == .success && isSettable.boolValue
    }

    /// Convenience: resize a window by resolving its AX element internally.
    func resizeWindow(
        _ windowID: WindowID,
        to size: CGSize
    )
    async -> Bool {
        let result = await resizeWindowWithAccessibilityResult(windowID, to: size)
        return result.outcome == .applied || result.outcome == .noChange
    }

    /// Convenience: resize a window by resolving its AX element internally.
    func resizeWindowWithAccessibilityResult(
        _ windowID: WindowID,
        to size: CGSize
    )
    async -> WindowAccessibilityResizeResult {
        guard let axWindow = resolveAXWindow(for: windowID) else {
            MirageLogger.debug(.host, "Cannot resize window \(windowID): no AXUIElement")
            return WindowAccessibilityResizeResult(
                outcome: .failed,
                observedFrame: windowInfo(for: windowID)?.frame,
                reason: "noAXWindow"
            )
        }
        return await resizeWindowViaAccessibilityWithResult(windowID, to: size, axElement: axWindow)
    }

    /// Resizes a window using Accessibility size attributes.
    ///
    /// This is more reliable than CGS APIs for some apps because it goes through
    /// the app-owned window element rather than only the compositor window record.
    func resizeWindowViaAccessibility(
        _ windowID: WindowID,
        to size: CGSize,
        axElement: AXUIElement? = nil
    )
    async -> Bool {
        let result = await resizeWindowViaAccessibilityWithResult(
            windowID,
            to: size,
            axElement: axElement
        )
        return result.outcome == .applied || result.outcome == .noChange
    }

    /// Resizes a window using Accessibility size attributes and returns a structured terminal result.
    func resizeWindowViaAccessibilityWithResult(
        _ windowID: WindowID,
        to size: CGSize,
        axElement: AXUIElement? = nil
    )
    async -> WindowAccessibilityResizeResult {
        guard let element = axElement else {
            MirageLogger.debug(.host, "No AXUIElement provided for window \(windowID)")
            return WindowAccessibilityResizeResult(
                outcome: .failed,
                observedFrame: windowInfo(for: windowID)?.frame,
                reason: "missingAXElement"
            )
        }

        let tolerance: CGFloat = 3
        let beforeFrame = resolvedWindowFrame(windowID, axWindow: element)
        if let beforeFrame,
           abs(beforeFrame.width - size.width) <= tolerance,
           abs(beforeFrame.height - size.height) <= tolerance {
            return WindowAccessibilityResizeResult(
                outcome: .noChange,
                observedFrame: beforeFrame,
                reason: "alreadyAtRequestedSize"
            )
        }

        guard isAXAttributeSettable(element, attribute: kAXSizeAttribute as CFString) else {
            MirageLogger.debug(.host, "Cannot resize window \(windowID): AX size attribute is not settable")
            return WindowAccessibilityResizeResult(
                outcome: .notResizable,
                observedFrame: beforeFrame,
                reason: "sizeAttributeNotSettable"
            )
        }

        var mutableSize = size
        let sizeValue = AXValueCreate(.cgSize, &mutableSize)
        var result = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue as CFTypeRef)
        if result == .cannotComplete {
            _ = raiseWindow(windowID, axWindow: element)
            result = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue as CFTypeRef)
        }

        guard result == .success else {
            MirageLogger.debug(.host, "Failed to resize window \(windowID) via Accessibility: \(result)")
            return WindowAccessibilityResizeResult(
                outcome: .failed,
                observedFrame: resolvedWindowFrame(windowID, axWindow: element) ?? beforeFrame,
                reason: "setAttributeFailed:\(result.rawValue)"
            )
        }

        let maxAttempts = 6
        for attempt in 1 ... maxAttempts {
            let compositorFrame = windowInfo(for: windowID)?.frame
            let axFrame = axWindowFrame(element)
            let compositorMatches = if let compositorFrame {
                abs(compositorFrame.width - size.width) <= tolerance &&
                    abs(compositorFrame.height - size.height) <= tolerance
            } else {
                false
            }
            let axMatches = if let axFrame {
                abs(axFrame.width - size.width) <= tolerance &&
                    abs(axFrame.height - size.height) <= tolerance
            } else {
                false
            }

            if compositorMatches || (compositorFrame == nil && axMatches) {
                let observedCompositor = compositorFrame.map { "\($0.size)" } ?? "unknown"
                let observedAX = axFrame.map { "\($0.size)" } ?? "unknown"
                MirageLogger.host(
                    "Resized window \(windowID) to \(size) via Accessibility (compositor=\(observedCompositor), ax=\(observedAX), attempt \(attempt))"
                )
                return WindowAccessibilityResizeResult(
                    outcome: .applied,
                    observedFrame: compositorFrame ?? axFrame,
                    reason: "applied"
                )
            }
            if attempt < maxAttempts {
                do {
                    try await Task.sleep(for: .milliseconds(20))
                } catch {
                    return WindowAccessibilityResizeResult(
                        outcome: .failed,
                        observedFrame: compositorFrame ?? axFrame ?? beforeFrame,
                        reason: "cancelled"
                    )
                }
            }
        }

        let observedCompositorFrame = windowInfo(for: windowID)?.frame
        let observedAXFrame = axWindowFrame(element)
        let observedCompositorSizeText = if let observedCompositorFrame {
            "\(observedCompositorFrame.size)"
        } else {
            "unknown"
        }
        let observedAXSizeText = observedAXFrame.map { "\($0.size)" } ?? "unknown"
        MirageLogger.debug(
            .host,
            "Accessibility resize for window \(windowID) did not converge to \(size); compositor=\(observedCompositorSizeText), ax=\(observedAXSizeText)"
        )
        return WindowAccessibilityResizeResult(
            outcome: .failed,
            observedFrame: observedCompositorFrame ?? observedAXFrame ?? beforeFrame,
            reason: "didNotConverge"
        )
    }
}

#endif
