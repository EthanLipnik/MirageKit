//
//  MessageTypes+Clipboard.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/11/26.
//

import Foundation

/// Host-to-client shared clipboard availability update.
package struct SharedClipboardStatusMessage: Codable {
    /// Whether the host currently allows shared clipboard exchange for the session.
    package let enabled: Bool

    /// Creates a shared clipboard status payload.
    package init(enabled: Bool) {
        self.enabled = enabled
    }
}

/// High-level payload family carried by a shared clipboard update.
package enum SharedClipboardRepresentationKind: String, Codable {
    /// UTF-8 text content.
    case text

    /// Image content.
    case image

    /// File content.
    case file

    /// Metadata-only declaration for content Mirage does not transfer.
    case unsupported
}

/// Metadata describing a shared clipboard item.
package struct SharedClipboardRepresentation: Codable, Equatable {
    /// High-level payload family.
    package let kind: SharedClipboardRepresentationKind

    /// Uniform type identifier or MIME type, when known.
    package let contentType: String?

    /// Suggested filename for file representations.
    package let filename: String?

    /// Unencrypted payload byte count.
    package let byteCount: Int

    /// Creates metadata for a shared clipboard item.
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

/// Shared clipboard item update sent over the control channel.
package struct SharedClipboardUpdateMessage: Codable {
    /// Stable ID for all chunks belonging to the same local clipboard change.
    package let changeID: UUID

    /// Monotonic logical version used to order clipboard changes across peers.
    package let logicalVersion: UInt64

    /// Sender wall-clock timestamp in Unix milliseconds for diagnostics and recency windows.
    package let sentAtMs: Int64

    /// Metadata describing the item being transferred.
    package let representation: SharedClipboardRepresentation

    /// Encrypted payload bytes for this chunk, or `nil` for metadata-only updates.
    package let encryptedPayload: Data?

    /// Zero-based chunk index for multi-message payloads.
    package let chunkIndex: Int

    /// Total chunk count for this clipboard change.
    package let chunkCount: Int

    /// Creates a shared clipboard update payload.
    package init(
        changeID: UUID,
        logicalVersion: UInt64,
        sentAtMs: Int64,
        representation: SharedClipboardRepresentation,
        encryptedPayload: Data?,
        chunkIndex: Int = 0,
        chunkCount: Int = 1
    ) {
        self.changeID = changeID
        self.logicalVersion = logicalVersion
        self.sentAtMs = sentAtMs
        self.representation = representation
        self.encryptedPayload = encryptedPayload
        self.chunkIndex = chunkIndex
        self.chunkCount = chunkCount
    }

    /// Ordering token derived from the update version and change ID.
    package var orderingToken: MirageSharedClipboardOrderingToken {
        MirageSharedClipboardOrderingToken(
            logicalVersion: logicalVersion,
            changeID: changeID
        )
    }
}
