//
//  MirageMediaSecurityFastPathTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/7/26.
//

@testable import MirageKit
import CoreGraphics
import Foundation
import Testing

@Suite("Mirage Media Security Fast Path")
struct MirageMediaSecurityFastPathTests {
    @Test("Video raw-buffer encryption round trips")
    func videoRawBufferEncryptionRoundTrips() throws {
        let context = makeSecurityContext()
        let key = MirageMediaPacketKey(context: context)
        let payload = makePayload(byteCount: 1200)
        let header = FrameHeader(
            flags: [.keyframe, .encryptedPayload],
            streamID: 4,
            sequenceNumber: 77,
            timestamp: 123_456_789,
            frameNumber: 12,
            fragmentIndex: 1,
            fragmentCount: 3,
            payloadLength: UInt32(payload.count),
            frameByteCount: UInt32(payload.count * 3),
            checksum: 0,
            contentRect: .zero,
            dimensionToken: 0,
            epoch: 9
        )

        let encrypted = try payload.withUnsafeBytes { payloadBytes in
            try MirageMediaSecurity.encryptVideoPayload(
                payloadBytes,
                header: header,
                key: key,
                direction: .hostToClient
            )
        }

        #expect(encrypted.count == payload.count + MirageMediaSecurity.authTagLength)

        let decrypted = try MirageMediaSecurity.decryptVideoPayload(
            encrypted,
            header: header,
            key: key,
            direction: .hostToClient
        )
        #expect(decrypted == payload)
    }

    @Test("Audio raw-buffer encryption round trips")
    func audioRawBufferEncryptionRoundTrips() throws {
        let context = makeSecurityContext()
        let key = MirageMediaPacketKey(context: context)
        let payload = makePayload(byteCount: 900)
        let header = AudioPacketHeader(
            codec: .aacLC,
            flags: [.encryptedPayload],
            streamID: 2,
            sequenceNumber: 33,
            timestamp: 999_000,
            frameNumber: 8,
            fragmentIndex: 0,
            fragmentCount: 2,
            payloadLength: UInt16(payload.count),
            frameByteCount: UInt32(payload.count * 2),
            sampleRate: 48_000,
            channelCount: 2,
            samplesPerFrame: 1024,
            checksum: 0
        )

        let encrypted = try payload.withUnsafeBytes { payloadBytes in
            try MirageMediaSecurity.encryptAudioPayload(
                payloadBytes,
                header: header,
                key: key,
                direction: .hostToClient
            )
        }

        #expect(encrypted.count == payload.count + MirageMediaSecurity.authTagLength)

        let decrypted = try MirageMediaSecurity.decryptAudioPayload(
            encrypted,
            header: header,
            key: key,
            direction: .hostToClient
        )
        #expect(decrypted == payload)
    }

    @Test("Shared clipboard encryption uses AES-GCM combined payloads")
    func sharedClipboardEncryptionUsesCombinedPayload() throws {
        let context = makeSecurityContext()
        let payload = Data("Mirage clipboard round-trip".utf8)
        let encrypted = try MirageMediaSecurity.encryptClipboardPayload(payload, context: context)
        let decrypted = try MirageMediaSecurity.decryptClipboardPayload(encrypted, context: context)

        #expect(decrypted == payload)
        #expect(encrypted.count == payload.count + 12 + 16)
    }

    private func makePayload(byteCount: Int) -> Data {
        Data((0 ..< byteCount).map { UInt8(truncatingIfNeeded: $0) })
    }

    private func makeSecurityContext() -> MirageMediaSecurityContext {
        MirageMediaSecurityContext(
            sessionKey: Data((0 ..< MirageMediaSecurity.sessionKeyLength).map { UInt8(truncatingIfNeeded: $0) })
        )
    }
}
