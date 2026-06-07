//
//  AppStreamWindowCatalog+Accessibility.swift
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
import ApplicationServices

extension AppStreamWindowCatalog {
    /// Builds an Accessibility index of windows for one process.
    static func buildAccessibilityIndex(processID: pid_t) -> [WindowID: AccessibilityClassification]? {
        let appElement = AXUIElementCreateApplication(processID)
        let windows = HostAccessibilityWindowLookup.windows(in: appElement)
        guard !windows.isEmpty else { return nil }

        var index: [WindowID: AccessibilityClassification] = [:]
        index.reserveCapacity(windows.count)
        for axWindow in windows {
            guard let windowID = HostAccessibilityWindowLookup.id(of: axWindow) else { continue }

            let role = HostAccessibilityWindowLookup.stringAttribute(kAXRoleAttribute as CFString, from: axWindow)
            let subrole = HostAccessibilityWindowLookup.stringAttribute(kAXSubroleAttribute as CFString, from: axWindow)
            let isFocused = HostAccessibilityWindowLookup.boolAttribute(kAXFocusedAttribute as CFString, from: axWindow) ?? false
            let isMain = HostAccessibilityWindowLookup.boolAttribute(kAXMainAttribute as CFString, from: axWindow) ?? false
            let isModal = HostAccessibilityWindowLookup.boolAttribute("AXModal" as CFString, from: axWindow) ?? false

            var parentWindowID: WindowID?
            if let parentElement = HostAccessibilityWindowLookup.elementAttributeValue(
                axWindow,
                attribute: kAXParentAttribute as CFString
            ),
               let parent = HostAccessibilityWindowLookup.id(of: parentElement) {
                if parent != windowID {
                    parentWindowID = parent
                }
            }

            index[windowID] = AccessibilityClassification(
                role: role,
                subrole: subrole,
                parentWindowID: parentWindowID,
                isFocused: isFocused,
                isMain: isMain,
                isModal: isModal
            )
        }

        return index
    }
}
#endif
