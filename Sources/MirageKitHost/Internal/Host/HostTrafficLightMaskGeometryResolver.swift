//
//  HostTrafficLightMaskGeometryResolver.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/1/26.
//

import CoreGraphics
import Foundation
import MirageKit

#if os(macOS)
import ApplicationServices

/// Resolves host-side traffic-light geometry for visual masking.
enum HostTrafficLightMaskGeometryResolver {
    enum Source: String, Sendable {
        case ax
        case fallback
    }

    struct ButtonsHiddenState: Sendable {
        let close: Bool?
        let minimize: Bool?
        let zoom: Bool?

        var isEffectivelyHidden: Bool {
            close == true && minimize == true && zoom == true
        }

        static let unknown = ButtonsHiddenState(close: nil, minimize: nil, zoom: nil)
    }

    struct ResolvedGeometry: Sendable {
        let windowFramePoints: CGRect
        let clusterRectPoints: CGRect
        let buttonUnionRectInClusterPoints: CGRect?
        let buttonsHiddenState: ButtonsHiddenState
        let source: Source

        init(
            windowFramePoints: CGRect,
            clusterRectPoints: CGRect,
            buttonUnionRectInClusterPoints: CGRect? = nil,
            buttonsHiddenState: ButtonsHiddenState,
            source: Source
        ) {
            self.windowFramePoints = windowFramePoints
            self.clusterRectPoints = clusterRectPoints
            self.buttonUnionRectInClusterPoints = buttonUnionRectInClusterPoints
            self.buttonsHiddenState = buttonsHiddenState
            self.source = source
        }
    }

    struct CacheEntry: Sendable {
        let geometry: ResolvedGeometry
        let sampledAt: CFAbsoluteTime
        let sampledWindowFrame: CGRect
    }

    private static let clusterTrailingPadding: CGFloat = 10
    private static let clusterBottomPadding: CGFloat = 8
    private static let maxClusterWidth: CGFloat = 220
    private static let maxClusterHeight: CGFloat = 120

    static func resolve(
        windowID: WindowID,
        windowFramePoints: CGRect,
        appProcessID: pid_t?
    ) -> ResolvedGeometry {
        let fallbackRect = fallbackClusterRect(in: windowFramePoints)

        guard let axWindow = resolveAXWindow(windowID: windowID, appProcessID: appProcessID) else {
            return ResolvedGeometry(
                windowFramePoints: windowFramePoints,
                clusterRectPoints: fallbackRect,
                buttonsHiddenState: .unknown,
                source: .fallback
            )
        }

        let hiddenState = buttonsHiddenState(in: axWindow)
        guard let clusterGeometry = dynamicClusterGeometry(in: axWindow, windowFramePoints: windowFramePoints) else {
            return ResolvedGeometry(
                windowFramePoints: windowFramePoints,
                clusterRectPoints: fallbackRect,
                buttonsHiddenState: hiddenState,
                source: .fallback
            )
        }

        return ResolvedGeometry(
            windowFramePoints: windowFramePoints,
            clusterRectPoints: clusterGeometry.clusterRectPoints,
            buttonUnionRectInClusterPoints: clusterGeometry.buttonUnionRectInClusterPoints,
            buttonsHiddenState: hiddenState,
            source: .ax
        )
    }

    static func shouldUseCached(
        _ cache: CacheEntry,
        now: CFAbsoluteTime,
        windowFramePoints: CGRect,
        ttl: CFAbsoluteTime,
        frameTolerance: CGFloat
    ) -> Bool {
        if now - cache.sampledAt > ttl {
            return false
        }
        return framesAreClose(cache.sampledWindowFrame, windowFramePoints, tolerance: frameTolerance)
    }

    static func framesAreClose(
        _ lhs: CGRect,
        _ rhs: CGRect,
        tolerance: CGFloat
    ) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= tolerance &&
            abs(lhs.origin.y - rhs.origin.y) <= tolerance &&
            abs(lhs.size.width - rhs.size.width) <= tolerance &&
            abs(lhs.size.height - rhs.size.height) <= tolerance
    }

    static func fallbackClusterRect(in windowFramePoints: CGRect) -> CGRect {
        let fallback = HostTrafficLightProtectionPolicy.fallbackClusterSize
        guard windowFramePoints.width > 0, windowFramePoints.height > 0 else {
            return CGRect(origin: .zero, size: fallback)
        }

        let width = min(windowFramePoints.width, fallback.width)
        let height = min(windowFramePoints.height, fallback.height)
        return CGRect(x: 0, y: 0, width: width, height: height)
    }

    struct DynamicClusterGeometry: Sendable {
        let clusterRectPoints: CGRect
        let buttonUnionRectInClusterPoints: CGRect
    }

    static func dynamicClusterGeometry(in axWindow: AXUIElement, windowFramePoints: CGRect) -> DynamicClusterGeometry? {
        let buttonFrames = trafficLightButtonFrames(in: axWindow)
        return clusterGeometryFromButtonFrames(buttonFrames, windowFramePoints: windowFramePoints)
    }

    static func dynamicClusterRect(in axWindow: AXUIElement, windowFramePoints: CGRect) -> CGRect? {
        dynamicClusterGeometry(in: axWindow, windowFramePoints: windowFramePoints)?.clusterRectPoints
    }

    static func clusterRectFromButtonFrames(
        _ buttonFrames: [CGRect],
        windowFramePoints: CGRect
    ) -> CGRect? {
        clusterGeometryFromButtonFrames(buttonFrames, windowFramePoints: windowFramePoints)?.clusterRectPoints
    }

    static func clusterGeometryFromButtonFrames(
        _ buttonFrames: [CGRect],
        windowFramePoints: CGRect
    ) -> DynamicClusterGeometry? {
        guard !buttonFrames.isEmpty else { return nil }

        let unionRect = buttonFrames.dropFirst().reduce(buttonFrames[0]) { partial, next in
            partial.union(next)
        }

        let leadingInset = max(0, unionRect.minX - windowFramePoints.minX)
        let topInsetFromMinY = max(0, unionRect.minY - windowFramePoints.minY)
        let topInsetFromMaxY = max(0, windowFramePoints.maxY - unionRect.maxY)
        let inferredTopInset = min(topInsetFromMinY, topInsetFromMaxY)

        let fallback = HostTrafficLightProtectionPolicy.fallbackClusterSize
        let clusterWidth = max(
            fallback.width,
            leadingInset + unionRect.width + clusterTrailingPadding
        )
        let clusterHeight = max(
            fallback.height,
            inferredTopInset + unionRect.height + clusterBottomPadding
        )

        let clampedWidth = min(windowFramePoints.width, min(maxClusterWidth, clusterWidth))
        let clampedHeight = min(windowFramePoints.height, min(maxClusterHeight, clusterHeight))
        guard clampedWidth > 0, clampedHeight > 0 else { return nil }

        let clusterRect = CGRect(x: 0, y: 0, width: clampedWidth, height: clampedHeight)

        let unionX = min(max(leadingInset, 0), max(0, clampedWidth - 1))
        let unionY = min(max(inferredTopInset, 0), max(0, clampedHeight - 1))
        let unionWidth = min(unionRect.width, clampedWidth - unionX)
        let unionHeight = min(unionRect.height, clampedHeight - unionY)
        guard unionWidth > 0, unionHeight > 0 else { return nil }

        let buttonUnionRectInCluster = CGRect(
            x: unionX,
            y: unionY,
            width: unionWidth,
            height: unionHeight
        )

        return DynamicClusterGeometry(
            clusterRectPoints: clusterRect,
            buttonUnionRectInClusterPoints: buttonUnionRectInCluster
        )
    }

    static func resolveAXWindow(windowID: WindowID, appProcessID: pid_t?) -> AXUIElement? {
        if let appProcessID, appProcessID > 0 {
            let appElement = AXUIElementCreateApplication(appProcessID)
            if let axWindow = findAXWindowByID(appElement: appElement, windowID: windowID) {
                return axWindow
            }
        }

        guard let ownerPID = ownerProcessID(for: windowID) else { return nil }
        let appElement = AXUIElementCreateApplication(ownerPID)
        return findAXWindowByID(appElement: appElement, windowID: windowID)
    }

    static func findAXWindowByID(appElement: AXUIElement, windowID: WindowID) -> AXUIElement? {
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

    static func ownerProcessID(for windowID: WindowID) -> pid_t? {
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

    static func buttonsHiddenState(in axWindow: AXUIElement) -> ButtonsHiddenState {
        ButtonsHiddenState(
            close: hiddenState(in: axWindow, buttonAttribute: kAXCloseButtonAttribute as CFString),
            minimize: hiddenState(in: axWindow, buttonAttribute: kAXMinimizeButtonAttribute as CFString),
            zoom: hiddenState(in: axWindow, buttonAttribute: kAXZoomButtonAttribute as CFString)
        )
    }

    static func hiddenState(in axWindow: AXUIElement, buttonAttribute: CFString) -> Bool? {
        guard let button = elementAttributeValue(axWindow, attribute: buttonAttribute) else {
            return nil
        }
        return booleanAttributeValue(button, attribute: "AXHidden" as CFString)
    }

    static func trafficLightButtonFrames(in axWindow: AXUIElement) -> [CGRect] {
        let buttonAttributes: [CFString] = [
            kAXCloseButtonAttribute as CFString,
            kAXMinimizeButtonAttribute as CFString,
            kAXZoomButtonAttribute as CFString,
        ]

        var frames: [CGRect] = []
        for buttonAttribute in buttonAttributes {
            guard let button = elementAttributeValue(axWindow, attribute: buttonAttribute),
                  let frame = frame(of: button) else {
                continue
            }
            frames.append(frame)
        }
        return frames
    }

    static func elementAttributeValue(_ element: AXUIElement, attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }

        return unsafeDowncast(value, to: AXUIElement.self)
    }

    static func booleanAttributeValue(_ element: AXUIElement, attribute: CFString) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value else {
            return nil
        }

        if CFGetTypeID(value) == CFBooleanGetTypeID() {
            return CFBooleanGetValue((value as! CFBoolean))
        }

        if CFGetTypeID(value) == CFNumberGetTypeID() {
            return (value as! NSNumber).boolValue
        }

        return nil
    }

    static func frame(of element: AXUIElement) -> CGRect? {
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
}
#endif
