//
//  MirageClientStartupDiagnostics.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/31/26.
//

enum IncomingVideoPacketRejectionReason: String, Sendable {
    case streamIDMismatch
    case packetContextMissing
    case reassemblerMissing
    case invalidWireLength
    case decryptFailure
}
