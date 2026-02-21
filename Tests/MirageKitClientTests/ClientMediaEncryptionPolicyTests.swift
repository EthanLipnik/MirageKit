//
//  ClientMediaEncryptionPolicyTests.swift
//  MirageKit
//
//  Created by Codex on 2/21/26.
//
//  Coverage for client-side media encryption acceptance and packet-key caching.
//

@testable import MirageKit
@testable import MirageKitClient
import Testing

@Suite("Client Media Encryption Policy")
struct ClientMediaEncryptionPolicyTests {
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
        let context = MirageMediaSecurityContext(
            sessionKey: Data((0 ..< MirageMediaSecurity.sessionKeyLength).map { UInt8(truncatingIfNeeded: $0) }),
            udpRegistrationToken: Data(repeating: 0xA7, count: MirageMediaSecurity.registrationTokenLength)
        )

        service.setMediaSecurityContext(context)
        #expect(service.mediaSecurityContextForNetworking != nil)
        #expect(service.mediaSecurityPacketKeyForNetworking != nil)

        service.setMediaSecurityContext(nil)
        #expect(service.mediaSecurityContextForNetworking == nil)
        #expect(service.mediaSecurityPacketKeyForNetworking == nil)
    }
}
