//
//  ClientMediaEncryptionTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/21/26.
//
//  Coverage for client-side media encryption acceptance and packet-key caching.
//

@testable import MirageKit
@testable import MirageKitClient
import Foundation
import Testing
import MirageCore

@Suite("Client Media Encryption")
struct ClientMediaEncryptionTests {
    @Test("Client accepts unencrypted media only when local opt-in is enabled")
    func unencryptedMediaAcceptancePolicy() {
        #expect(
            MirageClientService.shouldAcceptSessionMediaEncryption(
                mediaEncryptionEnabled: true,
                requireEncryptedMediaOnLocalNetwork: false
            )
        )
        #expect(
            !MirageClientService.shouldAcceptSessionMediaEncryption(
                mediaEncryptionEnabled: false,
                requireEncryptedMediaOnLocalNetwork: true
            )
        )
        #expect(
            MirageClientService.shouldAcceptSessionMediaEncryption(
                mediaEncryptionEnabled: false,
                requireEncryptedMediaOnLocalNetwork: false
            )
        )
    }

    @MainActor
    @Test("Client caches precomputed media packet key with context updates")
    func packetKeyCacheTracksContextUpdates() {
        let service = MirageClientService()
        let streamID: StreamID = 42
        let context = MirageMediaSecurityContext(
            sessionKey: Data((0 ..< MirageMediaSecurity.sessionKeyLength).map { UInt8(truncatingIfNeeded: $0) })
        )
        service.fastPathState.addActiveStreamID(streamID)

        service.setMediaSecurityContext(context)
        #expect(service.fastPathState.videoPacketContext(for: streamID)?.mediaPacketKey != nil)

        service.setMediaSecurityContext(nil)
        #expect(service.fastPathState.videoPacketContext(for: streamID)?.mediaPacketKey == nil)
    }
}
