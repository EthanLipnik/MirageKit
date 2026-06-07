//
//  MirageSharedClipboardState.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/11/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageMedia
import MirageWire
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
    /// Time window for attributing platform pasteboard change-count advances to a remote clipboard update.
    package static let hostOriginAttributionWindowMilliseconds: Int64 = 8000

    package static func maximumPayloadBytes(for representation: MirageWire.SharedClipboardRepresentation) -> Int {
        representation.kind == .text ? maximumTextPayloadBytes : maximumBinaryPayloadBytes
    }

    package static func validatedPayload(
        _ payload: Data?,
        representation: MirageWire.SharedClipboardRepresentation
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

    package static func currentTimestampMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    package static func makeUpdateMessages(
        localSend: MirageSharedClipboardLocalSend,
        sentAtMs: Int64,
        mediaSecurityContext: MirageMediaSecurityContext
    ) throws -> [MirageWire.ControlMessage] {
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
            let update = MirageWire.SharedClipboardUpdateMessage(
                changeID: localSend.orderingToken.changeID,
                logicalVersion: localSend.orderingToken.logicalVersion,
                sentAtMs: sentAtMs,
                representation: localSend.item.representation,
                encryptedPayload: encryptedPayload,
                chunkIndex: index,
                chunkCount: chunks.count
            )
            return try MirageWire.ControlMessage(type: .sharedClipboardUpdate, content: update)
        }
    }
}

package struct MirageSharedClipboardItem: Equatable {
    package let representation: MirageWire.SharedClipboardRepresentation
    package let payload: Data?

    package init(representation: MirageWire.SharedClipboardRepresentation, payload: Data?) {
        self.representation = representation
        self.payload = payload
    }

    package static func unsupported(byteCount: Int = 0) -> MirageSharedClipboardItem {
        MirageSharedClipboardItem(
            representation: MirageWire.SharedClipboardRepresentation(
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
    package let orderingToken: MirageWire.MirageSharedClipboardOrderingToken
}

package struct MirageSharedClipboardState {
    package private(set) var isActive = false
    package private(set) var lastObservedChangeCount: Int?
    package private(set) var latestOrderingToken: MirageWire.MirageSharedClipboardOrderingToken?
    package private(set) var maxKnownLogicalVersion: UInt64 = 0
    package private(set) var suppressLocalSendUntilChangeCount: Int?
    package private(set) var latestRemoteClipboardObservationToken: MirageWire.MirageSharedClipboardOrderingToken?
    package private(set) var latestRemoteClipboardObservedAtMs: Int64?
    package private(set) var remoteOriginAttributionBaselineChangeCount: Int?
    package private(set) var remoteOriginAttributionDeadlineMs: Int64?
    package private(set) var remoteOriginAttributedChangeCountUpperBound: Int?

    package init() {}

    package mutating func activate(changeCount: Int) {
        isActive = true
        lastObservedChangeCount = changeCount
        latestOrderingToken = nil
        maxKnownLogicalVersion = 0
        suppressLocalSendUntilChangeCount = nil
        latestRemoteClipboardObservationToken = nil
        latestRemoteClipboardObservedAtMs = nil
        remoteOriginAttributionBaselineChangeCount = nil
        remoteOriginAttributionDeadlineMs = nil
        remoteOriginAttributedChangeCountUpperBound = nil
    }

    package mutating func deactivate() {
        isActive = false
        lastObservedChangeCount = nil
        latestOrderingToken = nil
        maxKnownLogicalVersion = 0
        suppressLocalSendUntilChangeCount = nil
        latestRemoteClipboardObservationToken = nil
        latestRemoteClipboardObservedAtMs = nil
        remoteOriginAttributionBaselineChangeCount = nil
        remoteOriginAttributionDeadlineMs = nil
        remoteOriginAttributedChangeCountUpperBound = nil
    }

    package func shouldApplyRemoteUpdate(
        orderingToken: MirageWire.MirageSharedClipboardOrderingToken
    ) -> Bool {
        guard let latestOrderingToken else { return true }
        return latestOrderingToken < orderingToken
    }

    package mutating func recordRemoteDeclaration(
        changeCount: Int,
        orderingToken: MirageWire.MirageSharedClipboardOrderingToken,
        observedAtMs: Int64? = nil
    ) {
        lastObservedChangeCount = changeCount
        latestOrderingToken = orderingToken
        maxKnownLogicalVersion = max(maxKnownLogicalVersion, orderingToken.logicalVersion)
        suppressLocalSendUntilChangeCount = changeCount
        if let observedAtMs {
            recordRemoteOriginAttributionWindow(
                changeCount: changeCount,
                orderingToken: orderingToken,
                observedAtMs: observedAtMs
            )
        }
    }

    package mutating func recordRemoteTransferObservation(
        changeCount: Int,
        orderingToken: MirageWire.MirageSharedClipboardOrderingToken,
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
        recordRemoteOriginAttributionWindow(
            changeCount: changeCount,
            orderingToken: orderingToken,
            observedAtMs: observedAtMs
        )
        return true
    }

    package mutating func recordRemoteWrite(
        changeCount: Int,
        orderingToken: MirageWire.MirageSharedClipboardOrderingToken,
        observedAtMs: Int64 = MirageSharedClipboard.currentTimestampMs()
    ) {
        lastObservedChangeCount = changeCount
        latestOrderingToken = orderingToken
        maxKnownLogicalVersion = max(maxKnownLogicalVersion, orderingToken.logicalVersion)
        suppressLocalSendUntilChangeCount = changeCount
        recordRemoteOriginAttributionWindow(
            changeCount: changeCount,
            orderingToken: orderingToken,
            observedAtMs: observedAtMs
        )
    }

    @discardableResult
    package mutating func recordPasteboardChangeObservation(
        changeCount: Int,
        observedAtMs: Int64 = MirageSharedClipboard.currentTimestampMs()
    ) -> Bool {
        guard isActive,
              let baselineChangeCount = remoteOriginAttributionBaselineChangeCount,
              let remoteObservedAtMs = latestRemoteClipboardObservedAtMs,
              let attributionDeadlineMs = remoteOriginAttributionDeadlineMs,
              observedAtMs >= remoteObservedAtMs,
              observedAtMs <= attributionDeadlineMs,
              changeCount > baselineChangeCount else {
            return false
        }
        lastObservedChangeCount = changeCount
        markRemoteOriginAttributedChangeCount(changeCount)
        return true
    }

    package func shouldSuppressLocalSend(changeCount: Int) -> Bool {
        if let suppressLocalSendUntilChangeCount,
           changeCount <= suppressLocalSendUntilChangeCount {
            return true
        }
        if let remoteOriginAttributedChangeCountUpperBound,
           changeCount <= remoteOriginAttributedChangeCountUpperBound {
            return true
        }
        return false
    }

    package mutating func recordSuppressedLocalSend(changeCount: Int) {
        lastObservedChangeCount = changeCount
        markRemoteOriginAttributedChangeCount(changeCount)
    }

    package mutating func prepareLocalSend(
        currentItem: MirageSharedClipboardItem,
        changeCount: Int
    ) -> MirageSharedClipboardLocalSend? {
        guard isActive else { return nil }
        if shouldSuppressLocalSend(changeCount: changeCount) {
            recordSuppressedLocalSend(changeCount: changeCount)
            return nil
        }

        lastObservedChangeCount = changeCount
        let orderingToken = mintLocalOrderingToken()
        latestOrderingToken = orderingToken
        suppressLocalSendUntilChangeCount = nil
        latestRemoteClipboardObservedAtMs = nil
        remoteOriginAttributionBaselineChangeCount = nil
        remoteOriginAttributionDeadlineMs = nil
        remoteOriginAttributedChangeCountUpperBound = nil
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
        if lastObservedChangeCount == changeCount {
            lastObservedChangeCount = changeCount
            return nil
        }

        guard item.payload != nil else {
            lastObservedChangeCount = changeCount
            let orderingToken = mintLocalOrderingToken()
            latestOrderingToken = orderingToken
            suppressLocalSendUntilChangeCount = nil
            latestRemoteClipboardObservedAtMs = nil
            remoteOriginAttributionBaselineChangeCount = nil
            remoteOriginAttributionDeadlineMs = nil
            remoteOriginAttributedChangeCountUpperBound = nil
            return MirageSharedClipboardLocalSend(
                item: item,
                orderingToken: orderingToken
            )
        }

        guard let localSend = prepareLocalSend(
            currentItem: item,
            changeCount: changeCount
        ) else {
            return nil
        }
        return localSend
    }

    private mutating func recordRemoteOriginAttributionWindow(
        changeCount: Int,
        orderingToken: MirageWire.MirageSharedClipboardOrderingToken,
        observedAtMs: Int64
    ) {
        latestRemoteClipboardObservationToken = orderingToken
        latestRemoteClipboardObservedAtMs = observedAtMs
        remoteOriginAttributionBaselineChangeCount = changeCount
        remoteOriginAttributionDeadlineMs = observedAtMs +
            MirageSharedClipboard.hostOriginAttributionWindowMilliseconds
        markRemoteOriginAttributedChangeCount(changeCount)
    }

    private mutating func markRemoteOriginAttributedChangeCount(_ changeCount: Int) {
        if let suppressLocalSendUntilChangeCount {
            self.suppressLocalSendUntilChangeCount = max(suppressLocalSendUntilChangeCount, changeCount)
        } else {
            suppressLocalSendUntilChangeCount = changeCount
        }
        if let remoteOriginAttributedChangeCountUpperBound {
            self.remoteOriginAttributedChangeCountUpperBound = max(
                remoteOriginAttributedChangeCountUpperBound,
                changeCount
            )
        } else {
            remoteOriginAttributedChangeCountUpperBound = changeCount
        }
    }

    private mutating func mintLocalOrderingToken() -> MirageWire.MirageSharedClipboardOrderingToken {
        maxKnownLogicalVersion &+= 1
        return MirageWire.MirageSharedClipboardOrderingToken(
            logicalVersion: maxKnownLogicalVersion,
            changeID: UUID()
        )
    }
}
