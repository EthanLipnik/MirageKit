//
//  MirageSharedClipboardState.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/11/26.
//

import Foundation

package enum MirageSharedClipboard {
    package static let maximumTextBytes = 32 * 1024
    package static let chunkSize = 4 * 1024

    package static func validatedText(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        guard text.utf8.count <= maximumTextBytes else { return nil }
        return text
    }

    package static func chunkText(_ text: String) -> [String] {
        let utf8 = Array(text.utf8)
        guard utf8.count > chunkSize else { return [text] }

        var chunks: [String] = []
        var offset = 0
        while offset < utf8.count {
            var end = min(offset + chunkSize, utf8.count)
            // Ensure we split at a character boundary. A valid split is where
            // utf8[end] is not a continuation byte (0b10xxxxxx).
            while end > offset, end < utf8.count, utf8[end] & 0xC0 == 0x80 {
                end -= 1
            }
            if end == offset { end = min(offset + chunkSize, utf8.count) }
            chunks.append(String(decoding: utf8[offset ..< end], as: UTF8.self))
            offset = end
        }
        return chunks
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

    package mutating func updateChangeCount(_ changeCount: Int) {
        lastObservedChangeCount = changeCount
    }

    package mutating func recordRemoteWrite(text: String, changeCount: Int) {
        pendingRemoteText = text
        lastObservedChangeCount = changeCount
    }

    package mutating func observeInitialText(
        _ text: String?,
        changeCount: Int
    ) -> MirageSharedClipboardObservationAction {
        guard isActive else { return .ignore }
        lastObservedChangeCount = changeCount
        guard let validatedText = MirageSharedClipboard.validatedText(text) else {
            return .ignore
        }
        return .send(validatedText)
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
