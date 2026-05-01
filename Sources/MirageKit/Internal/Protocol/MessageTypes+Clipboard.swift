//
//  MessageTypes+Clipboard.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/11/26.
//

import Foundation

package struct SharedClipboardStatusMessage: Codable, Sendable {
    package let enabled: Bool

    package init(enabled: Bool) {
        self.enabled = enabled
    }
}

package enum SharedClipboardSource: String, Codable, Sendable {
    case host
    case client
}

package enum SharedClipboardRepresentationKind: String, Codable, Sendable {
    case text
    case image
    case file
    case unsupported
}

package struct SharedClipboardRepresentation: Codable, Sendable, Equatable {
    package let kind: SharedClipboardRepresentationKind
    package let contentType: String?
    package let filename: String?
    package let byteCount: Int

    package init(
        kind: SharedClipboardRepresentationKind,
        contentType: String?,
        filename: String?,
        byteCount: Int
    ) {
        self.kind = kind
        self.contentType = contentType
        self.filename = filename
        self.byteCount = byteCount
    }
}

package struct SharedClipboardUpdateMessage: Codable, Sendable {
    package let changeID: UUID
    package let logicalVersion: UInt64
    package let sentAtMs: Int64
    package let source: SharedClipboardSource
    package let representation: SharedClipboardRepresentation
    package let isPayloadTransferable: Bool
    package let encryptedPayload: Data?
    package let chunkIndex: Int
    package let chunkCount: Int

    package init(
        changeID: UUID,
        logicalVersion: UInt64,
        sentAtMs: Int64,
        source: SharedClipboardSource,
        representation: SharedClipboardRepresentation,
        isPayloadTransferable: Bool,
        encryptedPayload: Data?,
        chunkIndex: Int = 0,
        chunkCount: Int = 1
    ) {
        self.changeID = changeID
        self.logicalVersion = logicalVersion
        self.sentAtMs = sentAtMs
        self.source = source
        self.representation = representation
        self.isPayloadTransferable = isPayloadTransferable
        self.encryptedPayload = encryptedPayload
        self.chunkIndex = chunkIndex
        self.chunkCount = chunkCount
    }

    package var orderingToken: MirageSharedClipboardOrderingToken {
        MirageSharedClipboardOrderingToken(
            logicalVersion: logicalVersion,
            changeID: changeID
        )
    }
}
