//
//  HostAccessibilityWindowLookup.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/13/26.
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

/// Shared Accessibility helpers for resolving host windows and reading AX element geometry.
enum HostAccessibilityWindowLookup {
    /// Resolves an Accessibility window from a CG window ID and an optional owning process hint.
    static func resolveWindow(windowID: WindowID, processID: pid_t?) -> AXUIElement? {
        if let processID, processID > 0 {
            let appElement = AXUIElementCreateApplication(processID)
            if let axWindow = window(in: appElement, matching: windowID) {
                return axWindow
            }
        }

        guard let ownerPID = ownerProcessID(for: windowID) else { return nil }
        let ownerElement = AXUIElementCreateApplication(ownerPID)
        return window(in: ownerElement, matching: windowID)
    }

    /// Finds the Accessibility window whose backing CG window ID matches.
    static func window(in appElement: AXUIElement, matching windowID: WindowID) -> AXUIElement? {
        let windows = windows(in: appElement)
        return window(matching: windowID, in: windows)
    }

    /// Finds the Accessibility window in a known window list whose backing CG window ID matches.
    static func window(matching windowID: WindowID, in windows: [AXUIElement]) -> AXUIElement? {
        guard !windows.isEmpty else { return nil }
        for axWindow in windows {
            if id(of: axWindow) == windowID {
                return axWindow
            }
        }
        return nil
    }

    /// Returns the CG window identifier backing an Accessibility window element.
    static func id(of axWindow: AXUIElement) -> WindowID? {
        var cgWindowID: CGWindowID = 0
        guard _AXUIElementGetWindow(axWindow, &cgWindowID) == .success else { return nil }
        return WindowID(cgWindowID)
    }

    /// Returns the Accessibility windows currently published by an application element.
    static func windows(in appElement: AXUIElement) -> [AXUIElement] {
        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)

        guard result == .success,
              let windows = windowsRef as? [AXUIElement] else {
            return []
        }
        return windows
    }

    /// Returns the process ID that owns a CG window.
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

    /// Reads an AX attribute whose value is another AX element.
    static func elementAttributeValue(_ element: AXUIElement, attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }

        return unsafeDowncast(value, to: AXUIElement.self)
    }

    /// Reads an AX attribute whose value is an array of AX elements.
    static func elementArrayAttributeValue(_ element: AXUIElement, attribute: CFString) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == CFArrayGetTypeID(),
              let array = value as? [AXUIElement] else {
            return nil
        }
        return array
    }

    /// Reads a string Accessibility attribute.
    static func stringAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &valueRef) == .success else { return nil }
        return valueRef as? String
    }

    /// Reads AX text that may be returned as either a plain or attributed string.
    static func textAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value else {
            return nil
        }

        if let stringValue = value as? String {
            return stringValue
        }
        if let attributedStringValue = value as? NSAttributedString {
            return attributedStringValue.string
        }
        return nil
    }

    /// Reads a Boolean Accessibility attribute, accepting CFBoolean and NSNumber-backed values.
    static func boolAttribute(_ attribute: CFString, from element: AXUIElement) -> Bool? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &valueRef) == .success,
              let valueRef else {
            return nil
        }
        if let bool = valueRef as? Bool { return bool }
        if let number = valueRef as? NSNumber {
            return number.boolValue
        }
        return nil
    }

    /// Returns AX frames for the close, minimize, and zoom buttons that exist.
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

    /// Returns the AX element frame when position and size attributes are available.
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

    /// Returns the AX element position when the position attribute is available.
    static func position(of element: AXUIElement) -> CGPoint? {
        var positionRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              let positionRef,
              CFGetTypeID(positionRef) == AXValueGetTypeID() else {
            return nil
        }

        var position = CGPoint.zero
        guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &position) else {
            return nil
        }
        return position
    }
}
#endif
