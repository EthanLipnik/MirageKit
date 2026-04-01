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

package struct MirageSharedClipboardOrderingToken: Sendable, Equatable, Comparable {
    package let logicalVersion: UInt64
    package let changeID: UUID

    package static func < (
        lhs: MirageSharedClipboardOrderingToken,
        rhs: MirageSharedClipboardOrderingToken
    ) -> Bool {
        if lhs.logicalVersion != rhs.logicalVersion {
            return lhs.logicalVersion < rhs.logicalVersion
        }
        return lhs.changeID.uuidString < rhs.changeID.uuidString
    }
}

package struct MirageSharedClipboardLocalSend: Sendable, Equatable {
    package let text: String
    package let orderingToken: MirageSharedClipboardOrderingToken
}

package enum MirageSharedClipboardObservationAction: Equatable, Sendable {
    case ignore
    case send(MirageSharedClipboardLocalSend)
}

package struct MirageSharedClipboardState: Sendable {
    package private(set) var isActive = false
    package private(set) var lastObservedChangeCount: Int?
    package private(set) var pendingRemoteText: String?
    package private(set) var lastRemoteText: String?
    package private(set) var lastRemoteChangeCount: Int?
    package private(set) var latestOrderingToken: MirageSharedClipboardOrderingToken?
    package private(set) var maxKnownLogicalVersion: UInt64 = 0

    package init() {}

    package mutating func activate(changeCount: Int) {
        isActive = true
        lastObservedChangeCount = changeCount
        pendingRemoteText = nil
        lastRemoteText = nil
        lastRemoteChangeCount = nil
        latestOrderingToken = nil
        maxKnownLogicalVersion = 0
    }

    package mutating func deactivate() {
        isActive = false
        lastObservedChangeCount = nil
        pendingRemoteText = nil
        lastRemoteText = nil
        lastRemoteChangeCount = nil
        latestOrderingToken = nil
        maxKnownLogicalVersion = 0
    }

    package mutating func recordObservedLocalChangeCount(_ changeCount: Int) {
        guard isActive else { return }
        guard lastObservedChangeCount != changeCount else { return }

        lastObservedChangeCount = changeCount
        pendingRemoteText = nil
        clearRemoteTextIfLocalChangeCountAdvanced(changeCount)
        latestOrderingToken = mintLocalOrderingToken()
    }

    package func shouldApplyRemoteText(
        orderingToken: MirageSharedClipboardOrderingToken
    ) -> Bool {
        guard let latestOrderingToken else { return true }
        return latestOrderingToken < orderingToken
    }

    package mutating func recordRemoteWrite(
        text: String,
        changeCount: Int,
        orderingToken: MirageSharedClipboardOrderingToken
    ) {
        pendingRemoteText = text
        lastRemoteText = text
        lastRemoteChangeCount = changeCount
        lastObservedChangeCount = changeCount
        latestOrderingToken = orderingToken
        maxKnownLogicalVersion = max(maxKnownLogicalVersion, orderingToken.logicalVersion)
    }

    package mutating func prepareManualLocalSend(
        currentText: String?,
        changeCount: Int
    ) -> MirageSharedClipboardLocalSend? {
        if let lastRemoteText, let lastRemoteChangeCount, changeCount <= lastRemoteChangeCount,
           let localSend = makeLocalSend(text: lastRemoteText, changeCount: changeCount) {
            return localSend
        }

        if let lastRemoteChangeCount, changeCount > lastRemoteChangeCount {
            lastRemoteText = nil
            self.lastRemoteChangeCount = nil
        }

        guard let currentText = MirageSharedClipboard.validatedText(currentText) else { return nil }
        return makeLocalSend(text: currentText, changeCount: changeCount)
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
        let validatedText = MirageSharedClipboard.validatedText(text)

        if let validatedText, pendingRemoteText == validatedText {
            pendingRemoteText = nil
            return .ignore
        }

        pendingRemoteText = nil
        clearRemoteTextIfLocalChangeCountAdvanced(changeCount)

        guard let validatedText else {
            latestOrderingToken = mintLocalOrderingToken()
            return .ignore
        }

        guard let localSend = makeLocalSend(text: validatedText, changeCount: changeCount) else {
            return .ignore
        }
        return .send(localSend)
    }

    private mutating func clearRemoteTextIfLocalChangeCountAdvanced(_ changeCount: Int) {
        if let lastRemoteChangeCount, changeCount > lastRemoteChangeCount {
            lastRemoteText = nil
            self.lastRemoteChangeCount = nil
        }
    }

    private mutating func makeLocalSend(
        text: String,
        changeCount: Int
    ) -> MirageSharedClipboardLocalSend? {
        guard let validatedText = MirageSharedClipboard.validatedText(text) else { return nil }

        lastObservedChangeCount = changeCount
        pendingRemoteText = nil
        lastRemoteText = nil
        lastRemoteChangeCount = nil

        let orderingToken = mintLocalOrderingToken()
        latestOrderingToken = orderingToken
        return MirageSharedClipboardLocalSend(
            text: validatedText,
            orderingToken: orderingToken
        )
    }

    private mutating func mintLocalOrderingToken() -> MirageSharedClipboardOrderingToken {
        maxKnownLogicalVersion &+= 1
        return MirageSharedClipboardOrderingToken(
            logicalVersion: maxKnownLogicalVersion,
            changeID: UUID()
        )
    }
}
