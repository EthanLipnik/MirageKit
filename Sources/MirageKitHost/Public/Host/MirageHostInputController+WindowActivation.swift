//
//  MirageHostInputController+WindowActivation.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Host input controller extensions.
//

import CoreGraphics
import Foundation
import MirageKit

#if os(macOS)
import AppKit
import ApplicationServices

extension MirageHostInputController {
    // MARK: - Window Activation (runs on accessibilityQueue)

    func activateWindow(
        windowID: WindowID,
        app: MirageApplication?
    ) {
        guard let app,
              let runningApp = NSRunningApplication(processIdentifier: app.id) else {
            return
        }

        runningApp.activate()

        let appElement = AXUIElementCreateApplication(app.id)
        AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)

        if let axWindow = findAXWindowByID(appElement: appElement, windowID: windowID) {
            AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(axWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
        } else {
            Task {
                await MainActor.run {
                    MirageHostService.bringWindowToFront(windowID)
                }
            }
        }
    }

    func beginTrafficLightProtection(
        windowID: WindowID,
        app: MirageApplication?,
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

    func dynamicTrafficLightClusterSize(
        windowID: WindowID,
        app: MirageApplication?,
        windowFrame: CGRect
    ) -> CGSize? {
        guard let axWindow = resolveAXWindow(windowID: windowID, app: app) else { return nil }
        let buttonFrames = trafficLightButtonFrames(in: axWindow)
        guard !buttonFrames.isEmpty else { return nil }

        let unionRect = buttonFrames.dropFirst().reduce(buttonFrames[0]) { partial, next in
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

    private func trafficLightButtonFrames(in axWindow: AXUIElement) -> [CGRect] {
        let buttonAttributes: [CFString] = [
            kAXCloseButtonAttribute as CFString,
            kAXMinimizeButtonAttribute as CFString,
            kAXZoomButtonAttribute as CFString,
        ]

        var frames: [CGRect] = []
        for buttonAttribute in buttonAttributes {
            guard let button = axElementAttributeValue(axWindow, attribute: buttonAttribute),
                  let frame = axFrame(of: button) else {
                continue
            }
            frames.append(frame)
        }
        return frames
    }

    func resolveAXWindow(windowID: WindowID, app: MirageApplication?) -> AXUIElement? {
        if let app {
            let appElement = AXUIElementCreateApplication(app.id)
            if let axWindow = findAXWindowByID(appElement: appElement, windowID: windowID) {
                return axWindow
            }
        }

        guard let ownerPID = ownerProcessID(for: windowID) else { return nil }
        let ownerElement = AXUIElementCreateApplication(ownerPID)
        return findAXWindowByID(appElement: ownerElement, windowID: windowID)
    }

    private func ownerProcessID(for windowID: WindowID) -> pid_t? {
        guard let windowList = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let windowInfo = windowList.first else {
            return nil
        }

        if let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t {
            return ownerPID
        }
        if let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? Int32 {
            return pid_t(ownerPID)
        }
        if let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? Int {
            return pid_t(ownerPID)
        }
        if let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? NSNumber {
            return pid_t(ownerPID.int32Value)
        }
        return nil
    }

    func findAXWindowByID(appElement: AXUIElement, windowID: WindowID) -> AXUIElement? {
        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)

        guard result == .success,
              let windows = windowsRef as? [AXUIElement] else {
            return nil
        }

        for axWindow in windows {
            var cgWindowID: CGWindowID = 0
            if _AXUIElementGetWindow(axWindow, &cgWindowID) == .success,
               cgWindowID == windowID {
                return axWindow
            }
        }
        return nil
    }

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

    private func hideTrafficLightButtonIfSupported(
        in axWindow: AXUIElement,
        buttonAttribute: CFString,
        buttonLabel: String,
        windowID: WindowID
    ) -> Bool? {
        guard let button = axElementAttributeValue(axWindow, attribute: buttonAttribute) else {
            MirageLogger.debug(
                .host,
                "Traffic-light protection hide unsupported for window \(windowID): missing \(buttonLabel) button"
            )
            return nil
        }

        let hiddenAttribute = "AXHidden" as CFString
        guard let existingValue = axBooleanAttributeValue(button, attribute: hiddenAttribute) else {
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

    private func restoreTrafficLightButtonIfNeeded(
        in axWindow: AXUIElement,
        buttonAttribute: CFString,
        buttonLabel: String,
        hiddenValue: Bool?,
        windowID: WindowID
    ) {
        guard let hiddenValue else { return }
        guard let button = axElementAttributeValue(axWindow, attribute: buttonAttribute) else {
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

    func axFrame(of element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef,
              let sizeRef,
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

    func axElementAttributeValue(_ element: AXUIElement, attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }

        return unsafeDowncast(value, to: AXUIElement.self)
    }

    func axBooleanAttributeValue(_ element: AXUIElement, attribute: CFString) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value else {
            return nil
        }

        if let boolValue = value as? Bool {
            return boolValue
        }

        if let numberValue = value as? NSNumber {
            return numberValue.boolValue
        }

        return nil
    }

    func isAXAttributeSettable(_ element: AXUIElement, attribute: CFString) -> Bool {
        var isSettable: DarwinBoolean = false
        let result = AXUIElementIsAttributeSettable(element, attribute, &isSettable)
        return result == .success && isSettable.boolValue
    }

    func setAXBooleanAttributeValue(_ element: AXUIElement, attribute: CFString, value: Bool) -> Bool {
        let targetValue: CFBoolean = value ? kCFBooleanTrue : kCFBooleanFalse
        return AXUIElementSetAttributeValue(element, attribute, targetValue) == .success
    }
}

#endif
