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
import MirageCore
import MirageWire

@Suite("Mirage Media Security Fast Path")
struct MirageMediaSecurityFastPathTests {
    @Test("Video raw-buffer encryption round trips")
    func videoRawBufferEncryptionRoundTrips() throws {
        let context = makeSecurityContext()
        let key = MirageMediaPacketKey(context: context)
        let payload = makePayload(byteCount: 1200)
        let header = MirageWire.FrameHeader(
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
        let header = MirageWire.AudioPacketHeader(
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

    @Test("Video nonce inputs are unique across current packet identity")
    func videoNonceInputsAreUniqueAcrossCurrentPacketIdentity() throws {
        let baseHeader = makeVideoHeader()
        let baseNonce = MirageMediaSecurity.videoNonceInputBytes(
            for: baseHeader,
            direction: .hostToClient
        )
        let nonces = [
            baseNonce,
            MirageMediaSecurity.videoNonceInputBytes(
                for: baseHeader,
                direction: .clientToHost
            ),
            MirageMediaSecurity.videoNonceInputBytes(
                for: makeVideoHeader(streamID: 0x1204),
                direction: .hostToClient
            ),
            MirageMediaSecurity.videoNonceInputBytes(
                for: makeVideoHeader(sequenceNumber: 0x0102_0305),
                direction: .hostToClient
            ),
            MirageMediaSecurity.videoNonceInputBytes(
                for: makeVideoHeader(fragmentIndex: 0x0507),
                direction: .hostToClient
            ),
            MirageMediaSecurity.videoNonceInputBytes(
                for: makeVideoHeader(epoch: 0x0008),
                direction: .hostToClient
            ),
        ]

        #expect(Set(nonces).count == nonces.count)
        #expect(baseNonce == Data([0x01, 0x01, 0x01, 0x07, 0x03, 0x12, 0x04, 0x03, 0x02, 0x01, 0x06, 0x05]))
        #expect(MirageMediaSecurity.videoNonceInputBytes(
            for: makeVideoHeader(frameNumber: baseHeader.frameNumber + 1),
            direction: .hostToClient
        ) == baseNonce)
    }

    @Test("Audio nonce inputs are unique across current packet identity")
    func audioNonceInputsAreUniqueAcrossCurrentPacketIdentity() throws {
        let baseHeader = makeAudioHeader()
        let baseNonce = MirageMediaSecurity.audioNonceInputBytes(
            for: baseHeader,
            direction: .hostToClient
        )
        let videoFamilyNonce = MirageMediaSecurity.videoNonceInputBytes(
            for: makeVideoHeader(),
            direction: .hostToClient
        )
        let nonces = [
            baseNonce,
            videoFamilyNonce,
            MirageMediaSecurity.audioNonceInputBytes(
                for: baseHeader,
                direction: .clientToHost
            ),
            MirageMediaSecurity.audioNonceInputBytes(
                for: makeAudioHeader(streamID: 0x1204),
                direction: .hostToClient
            ),
            MirageMediaSecurity.audioNonceInputBytes(
                for: makeAudioHeader(sequenceNumber: 0x0102_0305),
                direction: .hostToClient
            ),
            MirageMediaSecurity.audioNonceInputBytes(
                for: makeAudioHeader(fragmentIndex: 0x0507),
                direction: .hostToClient
            ),
        ]

        #expect(Set(nonces).count == nonces.count)
        #expect(baseNonce == Data([0x01, 0x01, 0x02, 0x00, 0x03, 0x12, 0x04, 0x03, 0x02, 0x01, 0x06, 0x05]))
        #expect(MirageMediaSecurity.audioNonceInputBytes(
            for: makeAudioHeader(frameNumber: baseHeader.frameNumber + 1),
            direction: .hostToClient
        ) == baseNonce)
    }

    private func makePayload(byteCount: Int) -> Data {
        Data((0 ..< byteCount).map { UInt8(truncatingIfNeeded: $0) })
    }

    private func makeSecurityContext() -> MirageMediaSecurityContext {
        MirageMediaSecurityContext(
            sessionKey: Data((0 ..< MirageMediaSecurity.sessionKeyLength).map { UInt8(truncatingIfNeeded: $0) })
        )
    }

    private func makeVideoHeader(
        streamID: StreamID = 0x1203,
        sequenceNumber: UInt32 = 0x0102_0304,
        frameNumber: UInt32 = 0xA0B0_C0D0,
        fragmentIndex: UInt16 = 0x0506,
        epoch: UInt16 = 0x0007
    ) -> MirageWire.FrameHeader {
        MirageWire.FrameHeader(
            flags: [.encryptedPayload],
            streamID: streamID,
            sequenceNumber: sequenceNumber,
            timestamp: 123_456,
            frameNumber: frameNumber,
            fragmentIndex: fragmentIndex,
            fragmentCount: 12,
            payloadLength: 16,
            frameByteCount: 128,
            checksum: 0,
            contentRect: .zero,
            dimensionToken: 0,
            epoch: epoch
        )
    }

    private func makeAudioHeader(
        streamID: StreamID = 0x1203,
        sequenceNumber: UInt32 = 0x0102_0304,
        frameNumber: UInt32 = 0xA0B0_C0D0,
        fragmentIndex: UInt16 = 0x0506
    ) -> MirageWire.AudioPacketHeader {
        MirageWire.AudioPacketHeader(
            codec: .aacLC,
            flags: [.encryptedPayload],
            streamID: streamID,
            sequenceNumber: sequenceNumber,
            timestamp: 123_456,
            frameNumber: frameNumber,
            fragmentIndex: fragmentIndex,
            fragmentCount: 12,
            payloadLength: 16,
            frameByteCount: 128,
            sampleRate: 48_000,
            channelCount: 2,
            samplesPerFrame: 1024,
            checksum: 0
        )
    }
}
