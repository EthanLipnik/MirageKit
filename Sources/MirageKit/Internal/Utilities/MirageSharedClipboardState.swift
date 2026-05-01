//
//  MirageSharedClipboardState.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/11/26.
//

import Foundation

package enum MirageSharedClipboard {
    package static let maximumPayloadBytes = 64 * 1024
    package static let chunkSize = 4 * 1024

    package static func validatedPayload(_ payload: Data?) -> Data? {
        guard let payload, !payload.isEmpty else { return nil }
        guard payload.count <= maximumPayloadBytes else { return nil }
        return payload
    }

    package static func chunkPayload(_ payload: Data) -> [Data] {
        guard payload.count > chunkSize else { return [payload] }

        var chunks: [Data] = []
        var offset = 0
        while offset < payload.count {
            let end = min(offset + chunkSize, payload.count)
            chunks.append(payload.subdata(in: offset ..< end))
            offset = end
        }
        return chunks
    }

    package static func currentTimestampMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    package static func makeUpdateMessages(
        localSend: MirageSharedClipboardLocalSend,
        sentAtMs: Int64,
        mediaSecurityContext: MirageMediaSecurityContext,
        source: SharedClipboardSource
    ) throws -> [ControlMessage] {
        let payload = localSend.item.payload.flatMap(validatedPayload)
        let chunks = payload.map(chunkPayload) ?? [Data()]
        return try chunks.enumerated().map { index, chunk in
            let encryptedPayload = try payload.map { _ in
                try MirageMediaSecurity.encryptClipboardPayload(
                    chunk,
                    context: mediaSecurityContext
                )
            }
            let update = SharedClipboardUpdateMessage(
                changeID: localSend.orderingToken.changeID,
                logicalVersion: localSend.orderingToken.logicalVersion,
                sentAtMs: sentAtMs,
                source: source,
                representation: localSend.item.representation,
                isPayloadTransferable: payload != nil,
                encryptedPayload: encryptedPayload,
                chunkIndex: index,
                chunkCount: chunks.count
            )
            return try ControlMessage(type: .sharedClipboardUpdate, content: update)
        }
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

package struct MirageSharedClipboardItem: Sendable, Equatable {
    package let representation: SharedClipboardRepresentation
    package let payload: Data?

    package init(representation: SharedClipboardRepresentation, payload: Data?) {
        self.representation = representation
        self.payload = payload
    }

    package static func unsupported(byteCount: Int = 0) -> MirageSharedClipboardItem {
        MirageSharedClipboardItem(
            representation: SharedClipboardRepresentation(
                kind: .unsupported,
                contentType: nil,
                filename: nil,
                byteCount: byteCount
            ),
            payload: nil
        )
    }
}

package struct MirageSharedClipboardLocalSend: Sendable, Equatable {
    package let item: MirageSharedClipboardItem
    package let orderingToken: MirageSharedClipboardOrderingToken

    package var hasPayload: Bool {
        item.payload != nil
    }
}

package struct MirageSharedClipboardState: Sendable {
    package private(set) var isActive = false
    package private(set) var lastObservedChangeCount: Int?
    package private(set) var latestOrderingToken: MirageSharedClipboardOrderingToken?
    package private(set) var maxKnownLogicalVersion: UInt64 = 0
    package private(set) var suppressLocalSendUntilChangeCount: Int?

    package init() {}

    package mutating func activate(changeCount: Int) {
        isActive = true
        lastObservedChangeCount = changeCount
        latestOrderingToken = nil
        maxKnownLogicalVersion = 0
        suppressLocalSendUntilChangeCount = nil
    }

    package mutating func deactivate() {
        isActive = false
        lastObservedChangeCount = nil
        latestOrderingToken = nil
        maxKnownLogicalVersion = 0
        suppressLocalSendUntilChangeCount = nil
    }

    package func shouldApplyRemoteUpdate(
        orderingToken: MirageSharedClipboardOrderingToken
    ) -> Bool {
        guard let latestOrderingToken else { return true }
        return latestOrderingToken < orderingToken
    }

    package mutating func recordRemoteDeclaration(
        changeCount: Int,
        orderingToken: MirageSharedClipboardOrderingToken
    ) {
        let localClipboardChanged = lastObservedChangeCount.map { changeCount > $0 } ?? false
        lastObservedChangeCount = changeCount
        latestOrderingToken = orderingToken
        maxKnownLogicalVersion = max(maxKnownLogicalVersion, orderingToken.logicalVersion)
        suppressLocalSendUntilChangeCount = localClipboardChanged ? nil : changeCount
    }

    package mutating func recordRemoteWrite(
        changeCount: Int,
        orderingToken: MirageSharedClipboardOrderingToken
    ) {
        lastObservedChangeCount = changeCount
        latestOrderingToken = orderingToken
        maxKnownLogicalVersion = max(maxKnownLogicalVersion, orderingToken.logicalVersion)
        suppressLocalSendUntilChangeCount = changeCount
    }

    package func shouldSuppressLocalSend(changeCount: Int) -> Bool {
        guard let suppressLocalSendUntilChangeCount else { return false }
        return changeCount <= suppressLocalSendUntilChangeCount
    }

    package mutating func recordObservedChangeCount(_ changeCount: Int) {
        lastObservedChangeCount = changeCount
    }

    package mutating func prepareLocalSend(
        currentItem: MirageSharedClipboardItem,
        changeCount: Int
    ) -> MirageSharedClipboardLocalSend? {
        guard isActive else { return nil }
        if let suppressLocalSendUntilChangeCount,
           changeCount <= suppressLocalSendUntilChangeCount {
            lastObservedChangeCount = changeCount
            return nil
        }

        lastObservedChangeCount = changeCount
        let orderingToken = mintLocalOrderingToken()
        latestOrderingToken = orderingToken
        suppressLocalSendUntilChangeCount = nil
        return MirageSharedClipboardLocalSend(
            item: currentItem,
            orderingToken: orderingToken
        )
    }

    package mutating func prepareLocalDeclaration(
        item: MirageSharedClipboardItem,
        changeCount: Int
    ) -> MirageSharedClipboardLocalSend? {
        guard isActive else { return nil }
        guard lastObservedChangeCount != changeCount else { return nil }
        return prepareLocalSend(currentItem: item, changeCount: changeCount)
    }

    private mutating func mintLocalOrderingToken() -> MirageSharedClipboardOrderingToken {
        maxKnownLogicalVersion &+= 1
        return MirageSharedClipboardOrderingToken(
            logicalVersion: maxKnownLogicalVersion,
            changeID: UUID()
        )
    }
}
