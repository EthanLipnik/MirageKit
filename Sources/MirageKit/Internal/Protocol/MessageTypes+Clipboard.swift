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
    package let sentAtMs: Int64
    package let encryptedText: Data

    package init(
        changeID: UUID,
        sentAtMs: Int64,
        encryptedText: Data
    ) {
        self.changeID = changeID
        self.sentAtMs = sentAtMs
        self.encryptedText = encryptedText
    }
}
