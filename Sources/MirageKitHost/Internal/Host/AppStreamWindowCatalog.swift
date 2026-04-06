//
//  AppStreamWindowCatalog.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/26/26.
//
//  Shared app-stream window cataloging and classification helpers.
//

import MirageKit
#if os(macOS)
import AppKit
import ApplicationServices
import Foundation
import ScreenCaptureKit

enum AppStreamWindowClassification: String, Sendable {
    case primary
    case auxiliary
}

struct AppStreamWindowCandidate: Sendable {
    let bundleIdentifier: String
    let window: MirageWindow
    let classification: AppStreamWindowClassification
    let role: String?
    let subrole: String?
    let parentWindowID: WindowID?
    let isFocused: Bool
    let isMain: Bool

    init(
        bundleIdentifier: String,
        window: MirageWindow,
        classification: AppStreamWindowClassification,
        role: String?,
        subrole: String?,
        parentWindowID: WindowID?,
        isFocused: Bool = false,
        isMain: Bool = false
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.window = window
        self.classification = classification
        self.role = role
        self.subrole = subrole
        self.parentWindowID = parentWindowID
        self.isFocused = isFocused
        self.isMain = isMain
    }

    var logMetadata: String {
        "classification=\(classification.rawValue), focused=\(isFocused), main=\(isMain), role=\(role ?? "nil"), subrole=\(subrole ?? "nil"), parent=\(parentWindowID.map(String.init) ?? "nil")"
    }
}

enum AppStreamWindowCatalog {
    struct AccessibilityClassification: Sendable {
        let role: String?
        let subrole: String?
        let parentWindowID: WindowID?
        let isFocused: Bool
        let isMain: Bool
    }

    static func catalog(
        for bundleIdentifiers: [String],
        minimumWindowSize: CGSize = CGSize(width: 160, height: 120)
    )
        async throws -> [String: [AppStreamWindowCandidate]] {
        let normalizedBundleIDs = Set(bundleIdentifiers.map { $0.lowercased() })
        guard !normalizedBundleIDs.isEmpty else { return [:] }

        let runningPIDsByBundleID = runningProcessIDs(for: normalizedBundleIDs)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        var candidatesByBundleID: [String: [AppStreamWindowCandidate]] = [:]
        var accessibilityByProcessID: [pid_t: [WindowID: AccessibilityClassification]] = [:]

        for window in content.windows {
            guard window.windowLayer == 0 else { continue }
            guard window.frame.width >= minimumWindowSize.width,
                  window.frame.height >= minimumWindowSize.height else { continue }
            guard let app = window.owningApplication else { continue }

            guard let matchedBundleID = matchedBundleIdentifier(
                for: app,
                normalizedBundleIDs: normalizedBundleIDs,
                runningPIDsByBundleID: runningPIDsByBundleID
            ) else { continue }

            let appModel = MirageApplication(
                id: app.processID,
                bundleIdentifier: app.bundleIdentifier,
                name: app.applicationName,
                iconData: nil
            )
            let normalizedWindow = MirageWindow(
                id: WindowID(window.windowID),
                title: window.title,
                application: appModel,
                frame: window.frame,
                isOnScreen: window.isOnScreen,
                windowLayer: Int(window.windowLayer)
            )

            let processID = app.processID
            let perProcessAccessibility: [WindowID: AccessibilityClassification]
            if let cached = accessibilityByProcessID[processID] {
                perProcessAccessibility = cached
            } else {
                let indexed = buildAccessibilityIndex(processID: processID) ?? [:]
                accessibilityByProcessID[processID] = indexed
                perProcessAccessibility = indexed
            }
            let accessibility = perProcessAccessibility[normalizedWindow.id]
            let classification = classifyWindow(
                role: accessibility?.role,
                subrole: accessibility?.subrole,
                parentWindowID: accessibility?.parentWindowID
            )

            let candidate = AppStreamWindowCandidate(
                bundleIdentifier: matchedBundleID,
                window: normalizedWindow,
                classification: classification,
                role: accessibility?.role,
                subrole: accessibility?.subrole,
                parentWindowID: accessibility?.parentWindowID,
                isFocused: accessibility?.isFocused ?? false,
                isMain: accessibility?.isMain ?? false
            )

            candidatesByBundleID[matchedBundleID, default: []].append(candidate)
        }

        for bundleID in candidatesByBundleID.keys {
            candidatesByBundleID[bundleID]?.sort(by: preferredOrder(lhs:rhs:))
        }

        return candidatesByBundleID
    }

    static func preferredOrder(lhs: AppStreamWindowCandidate, rhs: AppStreamWindowCandidate) -> Bool {
        if lhs.isFocused != rhs.isFocused { return lhs.isFocused }
        if lhs.isMain != rhs.isMain { return lhs.isMain }
        if lhs.window.isOnScreen != rhs.window.isOnScreen { return lhs.window.isOnScreen }
        if lhs.window.windowLayer != rhs.window.windowLayer { return lhs.window.windowLayer < rhs.window.windowLayer }

        let lhsArea = lhs.window.frame.width * lhs.window.frame.height
        let rhsArea = rhs.window.frame.width * rhs.window.frame.height
        if lhsArea != rhsArea { return lhsArea > rhsArea }

        return lhs.window.id < rhs.window.id
    }

    static func classifyWindow(
        role: String?,
        subrole: String?,
        parentWindowID: WindowID?
    ) -> AppStreamWindowClassification {
        if parentWindowID != nil { return .auxiliary }

        let roleLower = role?.lowercased() ?? ""
        if roleLower.contains("sheet") ||
            roleLower.contains("dialog") ||
            roleLower.contains("popover") ||
            roleLower.contains("drawer") ||
            roleLower.contains("floating") {
            return .auxiliary
        }

        let subroleLower = subrole?.lowercased() ?? ""
        if subroleLower.contains("dialog") ||
            subroleLower.contains("floating") ||
            subroleLower.contains("popover") ||
            subroleLower.contains("drawer") ||
            subroleLower.contains("utility") ||
            subroleLower.contains("panel") ||
            subroleLower.contains("system") {
            return .auxiliary
        }

        return .primary
    }

    private static func matchedBundleIdentifier(
        for app: SCRunningApplication,
        normalizedBundleIDs: Set<String>,
        runningPIDsByBundleID: [String: Set<pid_t>]
    ) -> String? {
        let ownerBundleID = app.bundleIdentifier.lowercased()
        if normalizedBundleIDs.contains(ownerBundleID) {
            return ownerBundleID
        }

        let ownerPID = app.processID
        return runningPIDsByBundleID.first { _, pids in
            pids.contains(ownerPID)
        }?.key
    }

    private static func runningProcessIDs(for normalizedBundleIDs: Set<String>) -> [String: Set<pid_t>] {
        var result: [String: Set<pid_t>] = [:]
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleIdentifier = app.bundleIdentifier?.lowercased(),
                  normalizedBundleIDs.contains(bundleIdentifier) else { continue }
            result[bundleIdentifier, default: []].insert(app.processIdentifier)
        }
        return result
    }

    private static func buildAccessibilityIndex(processID: pid_t) -> [WindowID: AccessibilityClassification]? {
        let appElement = AXUIElementCreateApplication(processID)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windowsRef,
              CFGetTypeID(windowsRef) == CFArrayGetTypeID(),
              let windows = windowsRef as? [AXUIElement] else {
            return nil
        }

        var index: [WindowID: AccessibilityClassification] = [:]
        index.reserveCapacity(windows.count)
        for axWindow in windows {
            var candidateWindowID: CGWindowID = 0
            guard _AXUIElementGetWindow(axWindow, &candidateWindowID) == .success else { continue }
            let windowID = WindowID(candidateWindowID)

            let role = stringAttribute(kAXRoleAttribute as CFString, from: axWindow)
            let subrole = stringAttribute(kAXSubroleAttribute as CFString, from: axWindow)
            let isFocused = boolAttribute(kAXFocusedAttribute as CFString, from: axWindow) ?? false
            let isMain = boolAttribute(kAXMainAttribute as CFString, from: axWindow) ?? false

            var parentWindowID: WindowID?
            var parentRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axWindow, kAXParentAttribute as CFString, &parentRef) == .success,
               let parentRef,
               CFGetTypeID(parentRef) == AXUIElementGetTypeID() {
                let parentElement = unsafeDowncast(parentRef, to: AXUIElement.self)
                var parentCGWindowID: CGWindowID = 0
                if _AXUIElementGetWindow(parentElement, &parentCGWindowID) == .success {
                    let parent = WindowID(parentCGWindowID)
                    if parent != windowID {
                        parentWindowID = parent
                    }
                }
            }

            index[windowID] = AccessibilityClassification(
                role: role,
                subrole: subrole,
                parentWindowID: parentWindowID,
                isFocused: isFocused,
                isMain: isMain
            )
        }

        return index
    }

    private static func stringAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &valueRef) == .success else { return nil }
        return valueRef as? String
    }

    private static func boolAttribute(_ attribute: CFString, from element: AXUIElement) -> Bool? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &valueRef) == .success else { return nil }
        guard let valueRef else { return nil }
        if let bool = valueRef as? Bool { return bool }
        if let number = valueRef as? NSNumber {
            return number.boolValue
        }
        return nil
    }
}

#endif
