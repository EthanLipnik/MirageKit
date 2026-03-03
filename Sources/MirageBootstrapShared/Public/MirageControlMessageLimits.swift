//
//  MirageControlMessageLimits.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/3/26.
//
//  Shared limits used by bootstrap control framing and replay protection.
//

import Foundation

public enum MirageControlMessageLimits {
    public static let maxBootstrapControlLineBytes = 64 * 1024
    public static let maxBootstrapCredentialCiphertextBytes = 16 * 1024
    public static let maxReplayNonceLength = 128
}
