//
//  MirageControlMessageLimits.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/23/26.
//
//  Shared limits used by Mirage control-channel framing and parsing.
//

import Foundation

/// Limits for TCP control-channel framing and buffering.
public enum MirageControlMessageLimits {
    /// Maximum allowed payload bytes for most control messages.
    public static let maxPayloadBytes = 8 * 1024 * 1024

    /// Maximum allowed payload bytes for `.appList` messages.
    public static let maxAppListPayloadBytes = 32 * 1024 * 1024

    /// Maximum allowed payload bytes for `.hostHardwareIcon` messages.
    public static let maxHostHardwareIconPayloadBytes = 4 * 1024 * 1024

    /// Maximum allowed total frame bytes (`type + length + payload`) for all control messages.
    public static let maxFrameBytes = maxAppListPayloadBytes + 5

    /// Maximum receive buffer size for control-channel parsing.
    public static let maxReceiveBufferBytes = 64 * 1024 * 1024

    /// Maximum hello frame bytes consumed during connection bootstrap.
    public static let maxHelloFrameBytes = 64 * 1024

    /// Maximum bootstrap control request/response line bytes.
    public static let maxBootstrapControlLineBytes = 64 * 1024

    /// Maximum ciphertext bytes accepted in bootstrap credential envelopes.
    public static let maxBootstrapCredentialCiphertextBytes = 16 * 1024

    /// Maximum nonce length accepted by replay protection.
    public static let maxReplayNonceLength = 128
}
