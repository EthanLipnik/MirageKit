//
//  MirageHostInputController+WindowActivation.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Host input controller extensions.
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

extension MirageHostInputController {
    // MARK: - Window Activation (runs on accessibilityQueue)

    /// Activates the owning app and raises the requested host window.
    func activateWindow(
        windowID: WindowID,
        app: MirageMedia.MirageApplication?
    ) {
        guard let app,
              let runningApp = NSRunningApplication(processIdentifier: app.id) else {
            return
        }

        runningApp.activate()

        let appElement = AXUIElementCreateApplication(app.id)
        AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)

        if let axWindow = HostAccessibilityWindowLookup.window(in: appElement, matching: windowID) {
            AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(axWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
        } else {
            Task {
                await MainActor.run {
                    MirageHostService.bringWindowToFrontIfPossible(windowID)
                }
            }
        }
    }

    /// Hides traffic-light buttons while a direct window stream is active.
    func beginTrafficLightProtection(
        windowID: WindowID,
        app: MirageMedia.MirageApplication?,
        usesVirtualDisplay: Bool
    ) {
        accessibilityQueue.async { [weak self] in
            guard let self else { return }

            trafficLightClusterCacheByWindowID.removeValue(forKey: windowID)
            lastTrafficLightBlockedLogTimeByWindowID.removeValue(forKey: windowID)

            guard !usesVirtualDisplay else {
                trafficLightVisibilitySnapshotByWindowID.removeValue(forKey: windowID)
                return
            }

            guard trafficLightVisibilitySnapshotByWindowID[windowID] == nil else { return }
            guard let axWindow = resolveAXWindow(windowID: windowID, app: app) else {
                MirageLogger.debug(
                    .host,
                    "Traffic-light protection hide skipped for window \(windowID): AX window unavailable"
                )
                return
            }

            guard let snapshot = hideTrafficLightsIfSupported(windowID: windowID, axWindow: axWindow),
                  snapshot.hasRecordedState else {
                return
            }

            trafficLightVisibilitySnapshotByWindowID[windowID] = snapshot
        }
    }

    /// Restores traffic-light button visibility after a stream ends.
    func endTrafficLightProtection(windowID: WindowID) {
        accessibilityQueue.async { [weak self] in
            guard let self else { return }

            trafficLightClusterCacheByWindowID.removeValue(forKey: windowID)
            lastTrafficLightBlockedLogTimeByWindowID.removeValue(forKey: windowID)

            guard let snapshot = trafficLightVisibilitySnapshotByWindowID.removeValue(forKey: windowID),
                  snapshot.hasRecordedState else {
                return
            }

            guard let axWindow = resolveAXWindow(windowID: windowID, app: nil) else {
                MirageLogger.debug(
                    .host,
                    "Traffic-light protection restore skipped for window \(windowID): AX window unavailable"
                )
                return
            }

            restoreTrafficLightsIfNeeded(snapshot, windowID: windowID, axWindow: axWindow)
        }
    }

    /// Computes the protected traffic-light cluster size from live AX button frames.
    func dynamicTrafficLightClusterSize(
        windowID: WindowID,
        app: MirageMedia.MirageApplication?,
        windowFrame: CGRect
    ) -> CGSize? {
        guard let axWindow = resolveAXWindow(windowID: windowID, app: app) else { return nil }
        let buttonFrames = HostAccessibilityWindowLookup.trafficLightButtonFrames(in: axWindow)
        guard !buttonFrames.isEmpty else { return nil }

        guard let firstButtonFrame = buttonFrames.first else { return nil }
        let unionRect = buttonFrames.dropFirst().reduce(firstButtonFrame) { partial, next in
            partial.union(next)
        }

        let leadingInset = max(0, unionRect.minX - windowFrame.minX)
        let topInsetFromMinY = max(0, unionRect.minY - windowFrame.minY)
        let topInsetFromMaxY = max(0, windowFrame.maxY - unionRect.maxY)
        let inferredTopInset = min(topInsetFromMinY, topInsetFromMaxY)

        let trailingPadding: CGFloat = 10
        let bottomPadding: CGFloat = 8
        let maxClusterWidth = min(windowFrame.width, 220)
        let maxClusterHeight = min(windowFrame.height, 120)

        let clusterWidth = min(maxClusterWidth, leadingInset + unionRect.width + trailingPadding)
        let clusterHeight = min(maxClusterHeight, inferredTopInset + unionRect.height + bottomPadding)
        guard clusterWidth.isFinite, clusterHeight.isFinite else { return nil }
        guard clusterWidth > 0, clusterHeight > 0 else { return nil }

        return CGSize(width: clusterWidth, height: clusterHeight)
    }

    /// Resolves an accessibility window by CG window ID.
    func resolveAXWindow(windowID: WindowID, app: MirageMedia.MirageApplication?) -> AXUIElement? {
        HostAccessibilityWindowLookup.resolveWindow(windowID: windowID, processID: app?.id)
    }

    /// Hides supported traffic-light buttons and returns the previous visibility snapshot.
    private func hideTrafficLightsIfSupported(
        windowID: WindowID,
        axWindow: AXUIElement
    ) -> HostTrafficLightVisibilitySnapshot? {
        let closeHidden = hideTrafficLightButtonIfSupported(
            in: axWindow,
            buttonAttribute: kAXCloseButtonAttribute as CFString,
            buttonLabel: "close",
            windowID: windowID
        )
        let minimizeHidden = hideTrafficLightButtonIfSupported(
            in: axWindow,
            buttonAttribute: kAXMinimizeButtonAttribute as CFString,
            buttonLabel: "minimize",
            windowID: windowID
        )
        let zoomHidden = hideTrafficLightButtonIfSupported(
            in: axWindow,
            buttonAttribute: kAXZoomButtonAttribute as CFString,
            buttonLabel: "zoom",
            windowID: windowID
        )

        let snapshot = HostTrafficLightVisibilitySnapshot(
            closeHidden: closeHidden,
            minimizeHidden: minimizeHidden,
            zoomHidden: zoomHidden
        )
        guard snapshot.hasRecordedState else { return nil }
        MirageLogger.host("Traffic-light protection enabled for window \(windowID)")
        return snapshot
    }

    /// Hides one traffic-light button when AXHidden is supported.
    private func hideTrafficLightButtonIfSupported(
        in axWindow: AXUIElement,
        buttonAttribute: CFString,
        buttonLabel: String,
        windowID: WindowID
    ) -> Bool? {
        guard let button = HostAccessibilityWindowLookup.elementAttributeValue(axWindow, attribute: buttonAttribute) else {
            MirageLogger.debug(
                .host,
                "Traffic-light protection hide unsupported for window \(windowID): missing \(buttonLabel) button"
            )
            return nil
        }

        let hiddenAttribute = "AXHidden" as CFString
        guard let existingValue = HostAccessibilityWindowLookup.boolAttribute(hiddenAttribute, from: button) else {
            MirageLogger.debug(
                .host,
                "Traffic-light protection hide unsupported for window \(windowID): \(buttonLabel) AXHidden unavailable"
            )
            return nil
        }

        guard isAXAttributeSettable(button, attribute: hiddenAttribute) else {
            MirageLogger.debug(
                .host,
                "Traffic-light protection hide unsupported for window \(windowID): \(buttonLabel) AXHidden not settable"
            )
            return nil
        }

        guard setAXBooleanAttributeValue(button, attribute: hiddenAttribute, value: true) else {
            MirageLogger.debug(
                .host,
                "Traffic-light protection hide failed for window \(windowID): \(buttonLabel) AXHidden set failed"
            )
            return nil
        }

        return existingValue
    }

    /// Restores all traffic-light buttons that were hidden for protection.
    private func restoreTrafficLightsIfNeeded(
        _ snapshot: HostTrafficLightVisibilitySnapshot,
        windowID: WindowID,
        axWindow: AXUIElement
    ) {
        restoreTrafficLightButtonIfNeeded(
            in: axWindow,
            buttonAttribute: kAXCloseButtonAttribute as CFString,
            buttonLabel: "close",
            hiddenValue: snapshot.closeHidden,
            windowID: windowID
        )
        restoreTrafficLightButtonIfNeeded(
            in: axWindow,
            buttonAttribute: kAXMinimizeButtonAttribute as CFString,
            buttonLabel: "minimize",
            hiddenValue: snapshot.minimizeHidden,
            windowID: windowID
        )
        restoreTrafficLightButtonIfNeeded(
            in: axWindow,
            buttonAttribute: kAXZoomButtonAttribute as CFString,
            buttonLabel: "zoom",
            hiddenValue: snapshot.zoomHidden,
            windowID: windowID
        )

        MirageLogger.host("Traffic-light protection restored for window \(windowID)")
    }

    /// Restores one traffic-light button to a recorded AXHidden value.
    private func restoreTrafficLightButtonIfNeeded(
        in axWindow: AXUIElement,
        buttonAttribute: CFString,
        buttonLabel: String,
        hiddenValue: Bool?,
        windowID: WindowID
    ) {
        guard let hiddenValue else { return }
        guard let button = HostAccessibilityWindowLookup.elementAttributeValue(axWindow, attribute: buttonAttribute) else {
            MirageLogger.debug(
                .host,
                "Traffic-light protection restore skipped for window \(windowID): missing \(buttonLabel) button"
            )
            return
        }

        let hiddenAttribute = "AXHidden" as CFString
        guard isAXAttributeSettable(button, attribute: hiddenAttribute) else {
            MirageLogger.debug(
                .host,
                "Traffic-light protection restore skipped for window \(windowID): \(buttonLabel) AXHidden not settable"
            )
            return
        }

        guard setAXBooleanAttributeValue(button, attribute: hiddenAttribute, value: hiddenValue) else {
            MirageLogger.debug(
                .host,
                "Traffic-light protection restore failed for window \(windowID): \(buttonLabel) AXHidden set failed"
            )
            return
        }
    }

    /// Returns whether an AX attribute can be set.
    func isAXAttributeSettable(_ element: AXUIElement, attribute: CFString) -> Bool {
        var isSettable: DarwinBoolean = false
        let result = AXUIElementIsAttributeSettable(element, attribute, &isSettable)
        return result == .success && isSettable.boolValue
    }

    /// Sets a Boolean AX attribute.
    func setAXBooleanAttributeValue(_ element: AXUIElement, attribute: CFString, value: Bool) -> Bool {
        let targetValue: CFBoolean = value ? kCFBooleanTrue : kCFBooleanFalse
        return AXUIElementSetAttributeValue(element, attribute, targetValue) == .success
    }
}

#endif
