//
//  MirageHostInputController+WindowClose.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/28/26.
//

import Foundation
import MirageKit

#if os(macOS)
import AppKit
import ApplicationServices

/// Result of attempting to close a host window.
enum HostWindowCloseAttemptResult {
    case closed
    case blocked(HostWindowCloseAlertSnapshot)
    case notClosed
}

/// Snapshot of a blocking close-confirmation alert.
struct HostWindowCloseAlertSnapshot {
    /// Alert title reported by Accessibility, when available.
    let title: String?

    /// Alert explanatory text reported by Accessibility, when available.
    let message: String?

    /// Pressable alert actions in the order presented by the host app.
    let actions: [HostWindowCloseAlertActionSnapshot]
}

/// Snapshot of one action in a blocking close-confirmation alert.
struct HostWindowCloseAlertActionSnapshot {
    /// Zero-based action index used when the client asks the host to press this button.
    let index: Int

    /// Visible button title.
    let title: String

    /// Whether the button appears to perform a destructive close/discard action.
    let isDestructive: Bool
}

/// AX button candidate extracted from a blocking alert.
private struct HostAlertButtonCandidate {
    /// Accessibility element backing the alert button.
    let element: AXUIElement

    /// Visible button title.
    let title: String
}

extension MirageHostInputController {
    /// Attempts to close a window and extracts any blocking confirmation alert.
    func attemptCloseWindowAndExtractBlockingAlert(
        windowID: WindowID,
        app: MirageApplication?
    ) async -> HostWindowCloseAttemptResult {
        await withCheckedContinuation { continuation in
            accessibilityQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: .notClosed)
                    return
                }

                guard let axWindow = resolveAXWindow(windowID: windowID, app: app) else {
                    continuation.resume(returning: .closed)
                    return
                }

                guard let closeButton = HostAccessibilityWindowLookup.elementAttributeValue(
                    axWindow,
                    attribute: kAXCloseButtonAttribute as CFString
                ) else {
                    continuation.resume(returning: .notClosed)
                    return
                }

                guard AXUIElementPerformAction(closeButton, kAXPressAction as CFString) == .success else {
                    continuation.resume(returning: .notClosed)
                    return
                }

                Thread.sleep(forTimeInterval: 0.2)

                guard let updatedWindow = resolveAXWindow(windowID: windowID, app: app) else {
                    continuation.resume(returning: .closed)
                    return
                }

                guard let alert = blockingAlertSnapshot(for: updatedWindow),
                      !alert.actions.isEmpty else {
                    continuation.resume(returning: .notClosed)
                    return
                }

                continuation.resume(returning: .blocked(alert))
            }
        }
    }

    /// Presses a previously reported blocking alert action.
    func pressBlockingAlertAction(
        windowID: WindowID,
        app: MirageApplication?,
        actionIndex: Int,
        fallbackTitle: String
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            accessibilityQueue.async { [weak self] in
                guard let self,
                      let axWindow = resolveAXWindow(windowID: windowID, app: app),
                      let alertElement = findBlockingAlertElement(for: axWindow) else {
                    continuation.resume(returning: false)
                    return
                }

                let buttons = alertButtons(in: alertElement)
                guard !buttons.isEmpty else {
                    continuation.resume(returning: false)
                    return
                }

                let chosenButton: HostAlertButtonCandidate?
                if buttons.indices.contains(actionIndex) {
                    let indexed = buttons[actionIndex]
                    if indexed.title == fallbackTitle {
                        chosenButton = indexed
                    } else {
                        chosenButton = buttons.first(where: { $0.title == fallbackTitle }) ?? indexed
                    }
                } else {
                    chosenButton = buttons.first(where: { $0.title == fallbackTitle })
                }

                guard let chosenButton else {
                    continuation.resume(returning: false)
                    return
                }

                let result = AXUIElementPerformAction(chosenButton.element, kAXPressAction as CFString)
                continuation.resume(returning: result == .success)
            }
        }
    }

    /// Builds a serializable snapshot from the blocking alert attached to a window.
    private func blockingAlertSnapshot(for axWindow: AXUIElement) -> HostWindowCloseAlertSnapshot? {
        guard let alertElement = findBlockingAlertElement(for: axWindow) else {
            return nil
        }

        let descendants = descendantElements(of: alertElement)
        var title = normalizedAXText(
            HostAccessibilityWindowLookup.textAttribute(kAXTitleAttribute as CFString, from: alertElement)
        )
        let staticTexts = descendants
            .filter { element in
                let role = HostAccessibilityWindowLookup.textAttribute(kAXRoleAttribute as CFString, from: element)?.lowercased()
                return role == "axstatictext"
            }
            .compactMap { element in
                normalizedAXText(
                    HostAccessibilityWindowLookup.textAttribute(kAXValueAttribute as CFString, from: element) ??
                        HostAccessibilityWindowLookup.textAttribute(kAXTitleAttribute as CFString, from: element)
                )
            }

        if title == nil {
            title = staticTexts.first
        }

        let messageLines = staticTexts.filter { line in
            guard let title else { return true }
            return line != title
        }
        let message = messageLines.isEmpty ? nil : messageLines.joined(separator: "\n")
        let buttons = alertButtons(in: alertElement)
        guard !buttons.isEmpty else { return nil }

        let actions = buttons.enumerated().map { index, button in
            HostWindowCloseAlertActionSnapshot(
                index: index,
                title: button.title,
                isDestructive: isDestructiveAlertActionTitle(button.title)
            )
        }
        return HostWindowCloseAlertSnapshot(
            title: title,
            message: message,
            actions: actions
        )
    }

    /// Finds the sheet, dialog, or alert blocking a close action.
    private func findBlockingAlertElement(for axWindow: AXUIElement) -> AXUIElement? {
        let sheetsAttribute = "AXSheets" as CFString
        if let sheets = HostAccessibilityWindowLookup.elementArrayAttributeValue(
            axWindow,
            attribute: sheetsAttribute
        ),
           let firstSheet = sheets.first {
            return firstSheet
        }

        let descendants = descendantElements(of: axWindow)
        for element in descendants {
            let role = HostAccessibilityWindowLookup.textAttribute(
                kAXRoleAttribute as CFString,
                from: element
            )?.lowercased() ?? ""
            let subrole = HostAccessibilityWindowLookup.textAttribute(
                kAXSubroleAttribute as CFString,
                from: element
            )?.lowercased() ?? ""
            if role.contains("sheet") || role.contains("dialog") || role.contains("alert") {
                return element
            }
            if subrole.contains("dialog") || subrole.contains("alert") {
                return element
            }
        }

        return nil
    }

    /// Returns titled buttons inside an alert element.
    private func alertButtons(in alertElement: AXUIElement) -> [HostAlertButtonCandidate] {
        let descendants = descendantElements(of: alertElement)
        var buttons: [HostAlertButtonCandidate] = []
        buttons.reserveCapacity(4)
        for element in descendants {
            let role = HostAccessibilityWindowLookup.textAttribute(
                kAXRoleAttribute as CFString,
                from: element
            )?.lowercased()
            guard role == "axbutton",
                  let title = normalizedAXText(
                      HostAccessibilityWindowLookup.textAttribute(kAXTitleAttribute as CFString, from: element)
                  ) else {
                continue
            }
            buttons.append(HostAlertButtonCandidate(element: element, title: title))
        }
        return buttons
    }

    /// Walks AX descendants breadth-first up to a bounded depth.
    private func descendantElements(of root: AXUIElement, maxDepth: Int = 6) -> [AXUIElement] {
        var result: [AXUIElement] = []
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var visited: Set<Int> = []

        while !queue.isEmpty {
            let (element, depth) = queue.removeFirst()
            let hash = Int(CFHash(element))
            if visited.contains(hash) {
                continue
            }
            visited.insert(hash)
            result.append(element)

            guard depth < maxDepth else { continue }
            let children = HostAccessibilityWindowLookup.elementArrayAttributeValue(
                element,
                attribute: kAXChildrenAttribute as CFString
            ) ?? []
            for child in children {
                queue.append((child, depth + 1))
            }
        }

        return result
    }

    /// Trims AX text and drops empty values.
    private func normalizedAXText(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Returns whether an alert action title is likely destructive.
    private func isDestructiveAlertActionTitle(_ title: String) -> Bool {
        let lower = title.lowercased()
        return lower.contains("don't save") ||
            lower.contains("delete") ||
            lower.contains("discard") ||
            lower.contains("remove") ||
            lower.contains("quit")
    }
}

#endif
