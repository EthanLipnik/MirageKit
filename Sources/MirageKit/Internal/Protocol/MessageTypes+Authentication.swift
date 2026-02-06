//
//  MessageTypes+Authentication.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Message type definitions.
//

import Foundation

// MARK: - Authentication Messages

package struct AuthRequestMessage: Codable {
    package let deviceID: UUID
    package let publicKey: Data

    package init(deviceID: UUID, publicKey: Data) {
        self.deviceID = deviceID
        self.publicKey = publicKey
    }
}

package struct AuthChallengeMessage: Codable {
    package let challenge: Data

    package init(challenge: Data) {
        self.challenge = challenge
    }
}

package struct AuthResponseMessage: Codable {
    package let signature: Data

    package init(signature: Data) {
        self.signature = signature
    }
}

package struct AuthResultMessage: Codable {
    package let success: Bool
    package let trusted: Bool
    package let errorMessage: String?

    package init(success: Bool, trusted: Bool, errorMessage: String? = nil) {
        self.success = success
        self.trusted = trusted
        self.errorMessage = errorMessage
    }
}
