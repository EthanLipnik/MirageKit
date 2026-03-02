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

enum HostWindowCloseAttemptResult: Sendable {
    case closed
    case blocked(HostWindowCloseAlertSnapshot)
    case notClosed
}

struct HostWindowCloseAlertSnapshot: Sendable {
    let title: String?
    let message: String?
    let actions: [HostWindowCloseAlertActionSnapshot]
}

struct HostWindowCloseAlertActionSnapshot: Sendable {
    let index: Int
    let title: String
    let isDestructive: Bool
}

private struct HostAlertButtonCandidate {
    let element: AXUIElement
    let title: String
}

extension MirageHostInputController {
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

                guard let axWindow = self.resolveAXWindow(windowID: windowID, app: app) else {
                    continuation.resume(returning: .closed)
                    return
                }

                guard let closeButton = self.axElementAttributeValue(
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

                guard let updatedWindow = self.resolveAXWindow(windowID: windowID, app: app) else {
                    continuation.resume(returning: .closed)
                    return
                }

                guard let alert = self.blockingAlertSnapshot(for: updatedWindow),
                      !alert.actions.isEmpty else {
                    continuation.resume(returning: .notClosed)
                    return
                }

                continuation.resume(returning: .blocked(alert))
            }
        }
    }

    func pressBlockingAlertAction(
        windowID: WindowID,
        app: MirageApplication?,
        actionIndex: Int,
        fallbackTitle: String
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            accessibilityQueue.async { [weak self] in
                guard let self,
                      let axWindow = self.resolveAXWindow(windowID: windowID, app: app),
                      let alertElement = self.findBlockingAlertElement(for: axWindow) else {
                    continuation.resume(returning: false)
                    return
                }

                let buttons = self.alertButtons(in: alertElement)
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

    private func blockingAlertSnapshot(for axWindow: AXUIElement) -> HostWindowCloseAlertSnapshot? {
        guard let alertElement = findBlockingAlertElement(for: axWindow) else {
            return nil
        }

        let descendants = descendantElements(of: alertElement)
        var title = normalizedAXText(
            axStringAttributeValue(alertElement, attribute: kAXTitleAttribute as CFString)
        )
        let staticTexts = descendants
            .filter { element in
                let role = axStringAttributeValue(element, attribute: kAXRoleAttribute as CFString)?.lowercased()
                return role == "axstatictext"
            }
            .compactMap { element in
                normalizedAXText(
                    axStringAttributeValue(element, attribute: kAXValueAttribute as CFString) ??
                        axStringAttributeValue(element, attribute: kAXTitleAttribute as CFString)
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

    private func findBlockingAlertElement(for axWindow: AXUIElement) -> AXUIElement? {
        let sheetsAttribute = "AXSheets" as CFString
        if let sheets = axElementArrayAttributeValue(axWindow, attribute: sheetsAttribute),
           let firstSheet = sheets.first {
            return firstSheet
        }

        let descendants = descendantElements(of: axWindow)
        for element in descendants {
            let role = axStringAttributeValue(element, attribute: kAXRoleAttribute as CFString)?.lowercased() ?? ""
            let subrole = axStringAttributeValue(element, attribute: kAXSubroleAttribute as CFString)?.lowercased() ?? ""
            if role.contains("sheet") || role.contains("dialog") || role.contains("alert") {
                return element
            }
            if subrole.contains("dialog") || subrole.contains("alert") {
                return element
            }
        }

        return nil
    }

    private func alertButtons(in alertElement: AXUIElement) -> [HostAlertButtonCandidate] {
        let descendants = descendantElements(of: alertElement)
        var buttons: [HostAlertButtonCandidate] = []
        buttons.reserveCapacity(4)
        for element in descendants {
            let role = axStringAttributeValue(element, attribute: kAXRoleAttribute as CFString)?.lowercased()
            guard role == "axbutton",
                  let title = normalizedAXText(
                      axStringAttributeValue(element, attribute: kAXTitleAttribute as CFString)
                  ) else {
                continue
            }
            buttons.append(HostAlertButtonCandidate(element: element, title: title))
        }
        return buttons
    }

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
            let children = axElementArrayAttributeValue(element, attribute: kAXChildrenAttribute as CFString) ?? []
            for child in children {
                queue.append((child, depth + 1))
            }
        }

        return result
    }

    private func axElementArrayAttributeValue(_ element: AXUIElement, attribute: CFString) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == CFArrayGetTypeID(),
              let array = value as? [AXUIElement] else {
            return nil
        }
        return array
    }

    private func axStringAttributeValue(_ element: AXUIElement, attribute: CFString) -> String? {
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

    private func normalizedAXText(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

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
