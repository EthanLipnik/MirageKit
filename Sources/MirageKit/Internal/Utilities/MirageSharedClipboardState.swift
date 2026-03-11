//
//  MirageSharedClipboardState.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/11/26.
//

import Foundation

package enum MirageSharedClipboard {
    package static let maximumTextBytes = 32 * 1024

    package static func validatedText(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        guard text.utf8.count <= maximumTextBytes else { return nil }
        return text
    }
}

package enum MirageSharedClipboardObservationAction: Equatable, Sendable {
    case ignore
    case send(String)
}

package struct MirageSharedClipboardState: Sendable {
    package private(set) var isActive = false
    package private(set) var lastObservedChangeCount: Int?
    package private(set) var pendingRemoteText: String?

    package init() {}

    package mutating func activate(changeCount: Int) {
        isActive = true
        lastObservedChangeCount = changeCount
        pendingRemoteText = nil
    }

    package mutating func deactivate() {
        isActive = false
        lastObservedChangeCount = nil
        pendingRemoteText = nil
    }

    package mutating func recordRemoteWrite(text: String, changeCount: Int) {
        pendingRemoteText = text
        lastObservedChangeCount = changeCount
    }

    package mutating func observeLocalText(
        _ text: String?,
        changeCount: Int
    ) -> MirageSharedClipboardObservationAction {
        guard isActive else { return .ignore }

        if lastObservedChangeCount == changeCount {
            if let validatedText = MirageSharedClipboard.validatedText(text),
               pendingRemoteText == validatedText {
                pendingRemoteText = nil
            }
            return .ignore
        }

        lastObservedChangeCount = changeCount

        guard let validatedText = MirageSharedClipboard.validatedText(text) else {
            pendingRemoteText = nil
            return .ignore
        }

        if pendingRemoteText == validatedText {
            pendingRemoteText = nil
            return .ignore
        }

        pendingRemoteText = nil
        return .send(validatedText)
    }
}
