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

    package static func currentTimestampMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
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
    package private(set) var lastRemoteText: String?
    package private(set) var lastRemoteChangeCount: Int?
    package private(set) var latestKnownSentAtMs: Int64?

    package init() {}

    package mutating func activate(changeCount: Int) {
        isActive = true
        lastObservedChangeCount = changeCount
        pendingRemoteText = nil
        lastRemoteText = nil
        lastRemoteChangeCount = nil
        latestKnownSentAtMs = nil
    }

    package mutating func deactivate() {
        isActive = false
        lastObservedChangeCount = nil
        pendingRemoteText = nil
        lastRemoteText = nil
        lastRemoteChangeCount = nil
        latestKnownSentAtMs = nil
    }

    package mutating func recordObservedLocalChangeCount(
        _ changeCount: Int,
        observedAtMs: Int64
    ) {
        guard isActive else { return }
        guard lastObservedChangeCount != changeCount else { return }

        lastObservedChangeCount = changeCount
        latestKnownSentAtMs = max(latestKnownSentAtMs ?? observedAtMs, observedAtMs)
        pendingRemoteText = nil

        if let lastRemoteChangeCount, changeCount > lastRemoteChangeCount {
            lastRemoteText = nil
            self.lastRemoteChangeCount = nil
        }
    }

    package mutating func recordManualLocalSend(
        changeCount: Int,
        sentAtMs: Int64
    ) {
        guard isActive else { return }

        lastObservedChangeCount = changeCount
        latestKnownSentAtMs = max(latestKnownSentAtMs ?? sentAtMs, sentAtMs)
        pendingRemoteText = nil
        lastRemoteText = nil
        lastRemoteChangeCount = nil
    }

    package func shouldApplyRemoteText(sentAtMs: Int64) -> Bool {
        guard let latestKnownSentAtMs else { return true }
        return sentAtMs >= latestKnownSentAtMs
    }

    package mutating func recordRemoteWrite(
        text: String,
        changeCount: Int,
        sentAtMs: Int64
    ) {
        pendingRemoteText = text
        lastRemoteText = text
        lastRemoteChangeCount = changeCount
        lastObservedChangeCount = changeCount
        latestKnownSentAtMs = max(latestKnownSentAtMs ?? sentAtMs, sentAtMs)
    }

    package mutating func preferredTextForManualLocalSync(
        currentText: String?,
        changeCount: Int
    ) -> String? {
        if let lastRemoteText, let lastRemoteChangeCount, changeCount <= lastRemoteChangeCount {
            return lastRemoteText
        }

        if let lastRemoteChangeCount, changeCount > lastRemoteChangeCount {
            lastRemoteText = nil
            self.lastRemoteChangeCount = nil
        }

        return MirageSharedClipboard.validatedText(currentText)
    }

    package mutating func observeLocalText(
        _ text: String?,
        changeCount: Int,
        sentAtMs: Int64
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
            if let lastRemoteChangeCount, changeCount > lastRemoteChangeCount {
                lastRemoteText = nil
                self.lastRemoteChangeCount = nil
            }
            return .ignore
        }

        if pendingRemoteText == validatedText {
            pendingRemoteText = nil
            return .ignore
        }

        latestKnownSentAtMs = max(latestKnownSentAtMs ?? sentAtMs, sentAtMs)
        pendingRemoteText = nil
        lastRemoteText = nil
        lastRemoteChangeCount = nil
        return .send(validatedText)
    }
}
