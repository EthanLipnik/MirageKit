//
//  MessageTypes+HostApplicationControl.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/12/26.
//
//  Host application control message definitions.
//

import Foundation

/// Request a Mirage Host app relaunch from the connected host (Client -> Host).
package struct HostApplicationRestartRequestMessage: Codable, Sendable {
    package init() {}
}

/// Result of a Mirage Host app relaunch request (Host -> Client).
package struct HostApplicationRestartResultMessage: Codable, Sendable {
    package let accepted: Bool
    package let message: String

    package init(
        accepted: Bool,
        message: String
    ) {
        self.accepted = accepted
        self.message = message
    }
}
