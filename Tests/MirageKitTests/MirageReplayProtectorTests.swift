//
//  MirageReplayProtectorTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/23/26.
//
//  Replay-protection bounds and nonce validation coverage.
//

@testable import MirageKit
import Foundation
import Testing

@Suite("Replay Protector")
struct MirageReplayProtectorTests {
    @Test("Replay protector rejects duplicate nonce")
    func replayProtectorRejectsDuplicateNonce() async {
        let protector = MirageReplayProtector(
            allowedClockSkewMs: 60_000,
            maxEntries: 8,
            maxNonceLength: 64
        )
        let now = Int64(Date().timeIntervalSince1970 * 1000)

        let firstAccepted = await protector.validate(timestampMs: now, nonce: "nonce-1")
        let secondAccepted = await protector.validate(timestampMs: now, nonce: "nonce-1")

        #expect(firstAccepted == true)
        #expect(secondAccepted == false)
    }

    @Test("Replay protector rejects oversized nonce")
    func replayProtectorRejectsOversizedNonce() async {
        let protector = MirageReplayProtector(
            allowedClockSkewMs: 60_000,
            maxEntries: 8,
            maxNonceLength: 32
        )
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let oversizedNonce = String(repeating: "x", count: 33)

        let accepted = await protector.validate(timestampMs: now, nonce: oversizedNonce)
        #expect(accepted == false)
    }

    @Test("Replay protector evicts oldest nonce when entry cap is reached")
    func replayProtectorEvictsOldestNonceAtCap() async {
        let protector = MirageReplayProtector(
            allowedClockSkewMs: 60_000,
            maxEntries: 3,
            maxNonceLength: 64
        )
        let now = Int64(Date().timeIntervalSince1970 * 1000)

        #expect(await protector.validate(timestampMs: now, nonce: "n1") == true)
        #expect(await protector.validate(timestampMs: now, nonce: "n2") == true)
        #expect(await protector.validate(timestampMs: now, nonce: "n3") == true)
        #expect(await protector.validate(timestampMs: now, nonce: "n4") == true)
        #expect(await protector.validate(timestampMs: now, nonce: "n1") == true)
    }
}
