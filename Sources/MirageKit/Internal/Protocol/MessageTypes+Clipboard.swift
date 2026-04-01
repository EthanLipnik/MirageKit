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

package struct SharedClipboardUpdateMessage: Codable, Sendable {
    package let changeID: UUID
    package let logicalVersion: UInt64
    package let sentAtMs: Int64
    package let encryptedText: Data
    package let chunkIndex: Int
    package let chunkCount: Int

    package init(
        changeID: UUID,
        logicalVersion: UInt64,
        sentAtMs: Int64,
        encryptedText: Data,
        chunkIndex: Int = 0,
        chunkCount: Int = 1
    ) {
        self.changeID = changeID
        self.logicalVersion = logicalVersion
        self.sentAtMs = sentAtMs
        self.encryptedText = encryptedText
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
