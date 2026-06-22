//
//  MirageHostApplicationControlMessages.swift
//  MirageWire
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation

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
