//
//  MirageSharedClipboardState.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/11/26.
//

import Foundation

package enum MirageSharedClipboard {
    /// Maximum payload size for binary clipboard representations.
    package static let maximumBinaryPayloadBytes = 64 * 1024
    /// Maximum payload size for text clipboard representations.
    package static let maximumTextPayloadBytes = 256 * 1024
    /// Target byte count for each shared-clipboard transfer chunk.
    package static let chunkSize = 4 * 1024
    /// Delay between chunks when pacing automatic shared-clipboard sends.
    package static let automaticStreamChunkPacingDelay: Duration = .milliseconds(12)
    /// Time window for suppressing local echo after applying a remote clipboard update.
    package static let recentRemoteClipboardChangeWindowMilliseconds: Int64 = 3000

    /// Metadata fingerprint used to detect repeated local clipboard declarations.
    package struct ContentFingerprint: Equatable {
        /// Clipboard representation family, such as text, image, file, or unsupported.
        package let kind: SharedClipboardRepresentationKind
        /// MIME or platform content type associated with the representation.
        package let contentType: String?
        /// Original filename for file-backed clipboard payloads.
        package let filename: String?
        /// Declared payload size in bytes.
        package let byteCount: Int
        /// Stable hash of the payload bytes, when the payload is available locally.
        package let payloadHash: UInt64?
    }

    package static func maximumPayloadBytes(for representation: SharedClipboardRepresentation) -> Int {
        representation.kind == .text ? maximumTextPayloadBytes : maximumBinaryPayloadBytes
    }

    package static func validatedPayload(
        _ payload: Data?,
        representation: SharedClipboardRepresentation
    ) -> Data? {
        guard let payload, !payload.isEmpty else { return nil }
        guard payload.count <= maximumPayloadBytes(for: representation) else { return nil }
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

    package static func contentFingerprint(for item: MirageSharedClipboardItem) -> ContentFingerprint {
        ContentFingerprint(
            kind: item.representation.kind,
            contentType: item.representation.contentType,
            filename: item.representation.filename,
            byteCount: item.representation.byteCount,
            payloadHash: item.payload.map(stablePayloadHash(_:))
        )
    }

    private static func stablePayloadHash(_ payload: Data) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in payload {
            hash ^= UInt64(byte)
            hash &*= 0x100_0000_01B3
        }
        return hash
    }

    package static func currentTimestampMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    package static func makeUpdateMessages(
        localSend: MirageSharedClipboardLocalSend,
        sentAtMs: Int64,
        mediaSecurityContext: MirageMediaSecurityContext
    ) throws -> [ControlMessage] {
        let payload = validatedPayload(
            localSend.item.payload,
            representation: localSend.item.representation
        )
        let chunks = payload.map(chunkPayload) ?? [Data()]
        return try chunks.enumerated().map { index, chunk in
            let encryptedPayload: Data? = if payload == nil {
                nil
            } else {
                try MirageMediaSecurity.encryptClipboardPayload(
                    chunk,
                    context: mediaSecurityContext
                )
            }
            let update = SharedClipboardUpdateMessage(
                changeID: localSend.orderingToken.changeID,
                logicalVersion: localSend.orderingToken.logicalVersion,
                sentAtMs: sentAtMs,
                representation: localSend.item.representation,
                encryptedPayload: encryptedPayload,
                chunkIndex: index,
                chunkCount: chunks.count
            )
            return try ControlMessage(type: .sharedClipboardUpdate, content: update)
        }
    }
}

package struct MirageSharedClipboardOrderingToken: Equatable, Comparable {
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

package struct MirageSharedClipboardItem: Equatable {
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

package struct MirageSharedClipboardLocalSend: Equatable {
    package let item: MirageSharedClipboardItem
    package let orderingToken: MirageSharedClipboardOrderingToken
}

package struct MirageSharedClipboardState {
    package private(set) var isActive = false
    package private(set) var lastObservedChangeCount: Int?
    package private(set) var latestOrderingToken: MirageSharedClipboardOrderingToken?
    package private(set) var maxKnownLogicalVersion: UInt64 = 0
    package private(set) var suppressLocalSendUntilChangeCount: Int?
    package private(set) var latestAutomaticLocalFingerprint: MirageSharedClipboard.ContentFingerprint?
    package private(set) var latestRemoteClipboardObservationToken: MirageSharedClipboardOrderingToken?
    package private(set) var latestRemoteClipboardObservedAtMs: Int64?

    package init() {}

    package mutating func activate(changeCount: Int) {
        isActive = true
        lastObservedChangeCount = changeCount
        latestOrderingToken = nil
        maxKnownLogicalVersion = 0
        suppressLocalSendUntilChangeCount = nil
        latestAutomaticLocalFingerprint = nil
        latestRemoteClipboardObservationToken = nil
        latestRemoteClipboardObservedAtMs = nil
    }

    package mutating func deactivate() {
        isActive = false
        lastObservedChangeCount = nil
        latestOrderingToken = nil
        maxKnownLogicalVersion = 0
        suppressLocalSendUntilChangeCount = nil
        latestAutomaticLocalFingerprint = nil
        latestRemoteClipboardObservationToken = nil
        latestRemoteClipboardObservedAtMs = nil
    }

    package func shouldApplyRemoteUpdate(
        orderingToken: MirageSharedClipboardOrderingToken
    ) -> Bool {
        guard let latestOrderingToken else { return true }
        return latestOrderingToken < orderingToken
    }

    package mutating func recordRemoteDeclaration(
        changeCount: Int,
        orderingToken: MirageSharedClipboardOrderingToken,
        observedAtMs: Int64? = nil
    ) {
        lastObservedChangeCount = changeCount
        latestOrderingToken = orderingToken
        maxKnownLogicalVersion = max(maxKnownLogicalVersion, orderingToken.logicalVersion)
        suppressLocalSendUntilChangeCount = changeCount
        latestAutomaticLocalFingerprint = nil
        if let observedAtMs {
            latestRemoteClipboardObservationToken = orderingToken
            latestRemoteClipboardObservedAtMs = observedAtMs
        }
    }

    package mutating func recordRemoteTransferObservation(
        changeCount: Int,
        orderingToken: MirageSharedClipboardOrderingToken,
        observedAtMs: Int64 = MirageSharedClipboard.currentTimestampMs()
    ) -> Bool {
        guard isActive else { return false }
        guard shouldApplyRemoteUpdate(orderingToken: orderingToken) else { return false }
        if let latestRemoteClipboardObservationToken,
           orderingToken <= latestRemoteClipboardObservationToken {
            return false
        }

        lastObservedChangeCount = changeCount
        maxKnownLogicalVersion = max(maxKnownLogicalVersion, orderingToken.logicalVersion)
        suppressLocalSendUntilChangeCount = changeCount
        latestAutomaticLocalFingerprint = nil
        latestRemoteClipboardObservationToken = orderingToken
        latestRemoteClipboardObservedAtMs = observedAtMs
        return true
    }

    package mutating func recordRemoteWrite(
        changeCount: Int,
        orderingToken: MirageSharedClipboardOrderingToken
    ) {
        lastObservedChangeCount = changeCount
        latestOrderingToken = orderingToken
        maxKnownLogicalVersion = max(maxKnownLogicalVersion, orderingToken.logicalVersion)
        suppressLocalSendUntilChangeCount = changeCount
        latestAutomaticLocalFingerprint = nil
    }

    package func shouldSuppressLocalSend(
        changeCount: Int,
        nowMs: Int64 = MirageSharedClipboard.currentTimestampMs()
    ) -> Bool {
        if let suppressLocalSendUntilChangeCount,
           changeCount <= suppressLocalSendUntilChangeCount {
            return true
        }
        guard let latestRemoteClipboardObservedAtMs else { return false }
        let elapsedMs = nowMs - latestRemoteClipboardObservedAtMs
        return elapsedMs >= 0 &&
            elapsedMs <= MirageSharedClipboard.recentRemoteClipboardChangeWindowMilliseconds
    }

    package mutating func recordSuppressedLocalSend(changeCount: Int) {
        lastObservedChangeCount = changeCount
        if let suppressLocalSendUntilChangeCount {
            self.suppressLocalSendUntilChangeCount = max(suppressLocalSendUntilChangeCount, changeCount)
        } else {
            suppressLocalSendUntilChangeCount = changeCount
        }
    }

    package mutating func prepareLocalSend(
        currentItem: MirageSharedClipboardItem,
        changeCount: Int,
        nowMs: Int64 = MirageSharedClipboard.currentTimestampMs()
    ) -> MirageSharedClipboardLocalSend? {
        guard isActive else { return nil }
        if shouldSuppressLocalSend(changeCount: changeCount, nowMs: nowMs) {
            recordSuppressedLocalSend(changeCount: changeCount)
            return nil
        }

        lastObservedChangeCount = changeCount
        let orderingToken = mintLocalOrderingToken()
        latestOrderingToken = orderingToken
        suppressLocalSendUntilChangeCount = nil
        latestRemoteClipboardObservedAtMs = nil
        return MirageSharedClipboardLocalSend(
            item: currentItem,
            orderingToken: orderingToken
        )
    }

    package mutating func prepareLocalDeclaration(
        item: MirageSharedClipboardItem,
        changeCount: Int,
        nowMs: Int64 = MirageSharedClipboard.currentTimestampMs()
    ) -> MirageSharedClipboardLocalSend? {
        guard isActive else { return nil }
        guard item.representation.kind != .unsupported,
              item.payload != nil else {
            lastObservedChangeCount = changeCount
            latestAutomaticLocalFingerprint = nil
            return nil
        }
        let fingerprint = MirageSharedClipboard.contentFingerprint(for: item)
        if lastObservedChangeCount == changeCount || latestAutomaticLocalFingerprint == fingerprint {
            lastObservedChangeCount = changeCount
            return nil
        }
        guard let localSend = prepareLocalSend(
            currentItem: item,
            changeCount: changeCount,
            nowMs: nowMs
        ) else {
            return nil
        }
        latestAutomaticLocalFingerprint = fingerprint
        return localSend
    }

    private mutating func mintLocalOrderingToken() -> MirageSharedClipboardOrderingToken {
        maxKnownLogicalVersion &+= 1
        return MirageSharedClipboardOrderingToken(
            logicalVersion: maxKnownLogicalVersion,
            changeID: UUID()
        )
    }
}
