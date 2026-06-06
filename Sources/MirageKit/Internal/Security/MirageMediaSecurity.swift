//
//  MirageMediaSecurity.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/11/26.
//
//  Media session key derivation, registration authentication, and packet AEAD helpers.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageMedia
import MirageWire
import CryptoKit
import Foundation
import Loom

package enum MirageMediaDirection: UInt8, Sendable {
    case hostToClient = 1
    case clientToHost = 2
}

/// Prepared symmetric key used by packet fast paths to avoid rebuilding `SymmetricKey` per fragment.
package struct MirageMediaPacketKey {
    fileprivate let symmetricKey: SymmetricKey

    /// Creates the packet key from an established media security context.
    package init(context: MirageMediaSecurityContext) {
        symmetricKey = SymmetricKey(data: context.sessionKey)
    }
}

/// Per-session media encryption material derived after authenticated connection setup.
package struct MirageMediaSecurityContext: Sendable {
    /// AES-GCM session key shared by the host and client for media and clipboard payloads.
    package let sessionKey: Data

    /// Creates a media security context from already-derived keying material.
    package init(sessionKey: Data) {
        self.sessionKey = sessionKey
    }
}

package enum MirageMediaSecurityError: Error {
    case invalidRegistrationTokenLength
    case invalidEncryptedPayloadLength
    case invalidNonce
    case encryptFailed
    case decryptFailed
}

package enum MirageMediaSecurity {
    /// HKDF shared-info domain for Mirage protocol v2 media sessions.
    private static let sessionKeyDerivationInfo = Data("mirage-media-session-v2".utf8)
    /// Salt-domain marker that prevents media keys from colliding with other Loom-derived material.
    private static let derivationSaltType = "media-key-derivation-v2"

    package static let sessionKeyLength = 32
    package static let registrationTokenLength = 32
    package static let authTagLength = MirageWire.mirageMediaAuthTagSize

    package static func makeRegistrationToken() -> Data {
        let key = SymmetricKey(size: .bits256)
        return key.withUnsafeBytes { Data($0) }
    }

    @MainActor
    package static func deriveContext(
        identityManager: LoomIdentityManager,
        peerPublicKey: Data,
        hostID: UUID,
        clientID: UUID,
        hostKeyID: String,
        clientKeyID: String,
        hostNonce: String,
        clientNonce: String,
        datagramRegistrationToken: Data
    ) throws -> MirageMediaSecurityContext {
        guard datagramRegistrationToken.count == registrationTokenLength else {
            throw MirageMediaSecurityError.invalidRegistrationTokenLength
        }
        let salt = derivationSalt(
            hostID: hostID,
            clientID: clientID,
            hostKeyID: hostKeyID,
            clientKeyID: clientKeyID,
            hostNonce: hostNonce,
            clientNonce: clientNonce
        )
        let key = try identityManager.deriveSharedKey(
            with: peerPublicKey,
            salt: salt,
            sharedInfo: sessionKeyDerivationInfo,
            outputByteCount: sessionKeyLength
        )
        return MirageMediaSecurityContext(
            sessionKey: key
        )
    }

    @MainActor
    package static func deriveContextForAuthenticatedSession(
        identityManager: LoomIdentityManager,
        peerPublicKey: Data,
        hostID: UUID,
        clientID: UUID,
        hostKeyID: String,
        clientKeyID: String,
        datagramRegistrationToken: Data
    ) throws -> MirageMediaSecurityContext {
        try deriveContext(
            identityManager: identityManager,
            peerPublicKey: peerPublicKey,
            hostID: hostID,
            clientID: clientID,
            hostKeyID: hostKeyID,
            clientKeyID: clientKeyID,
            hostNonce: "loom-authenticated-host",
            clientNonce: "loom-authenticated-client",
            datagramRegistrationToken: datagramRegistrationToken
        )
    }

    package static func encryptVideoPayload(
        _ plaintext: UnsafeRawBufferPointer,
        header: MirageWire.FrameHeader,
        key: MirageMediaPacketKey,
        direction: MirageMediaDirection
    ) throws -> Data {
        try seal(
            plaintext,
            key: key.symmetricKey,
            nonce: videoNonce(for: header, direction: direction)
        )
    }

    package static func decryptVideoPayload<Payload: DataProtocol>(
        _ wirePayload: Payload,
        header: MirageWire.FrameHeader,
        key: MirageMediaPacketKey,
        direction: MirageMediaDirection
    ) throws -> Data {
        try open(
            wirePayload,
            key: key.symmetricKey,
            nonce: videoNonce(for: header, direction: direction)
        )
    }

    package static func encryptMosaicVideoPayload(
        _ plaintext: UnsafeRawBufferPointer,
        header: MirageWire.MirageMosaicPacketHeader,
        key: MirageMediaPacketKey,
        direction: MirageMediaDirection
    ) throws -> Data {
        try seal(
            plaintext,
            key: key.symmetricKey,
            nonce: mosaicVideoNonce(for: header, direction: direction)
        )
    }

    package static func decryptMosaicVideoPayload<Payload: DataProtocol>(
        _ wirePayload: Payload,
        header: MirageWire.MirageMosaicPacketHeader,
        key: MirageMediaPacketKey,
        direction: MirageMediaDirection
    ) throws -> Data {
        try open(
            wirePayload,
            key: key.symmetricKey,
            nonce: mosaicVideoNonce(for: header, direction: direction)
        )
    }

    package static func encryptAudioPayload(
        _ plaintext: UnsafeRawBufferPointer,
        header: MirageWire.AudioPacketHeader,
        key: MirageMediaPacketKey,
        direction: MirageMediaDirection
    ) throws -> Data {
        try seal(
            plaintext,
            key: key.symmetricKey,
            nonce: audioNonce(for: header, direction: direction)
        )
    }

    package static func decryptAudioPayload<Payload: DataProtocol>(
        _ wirePayload: Payload,
        header: MirageWire.AudioPacketHeader,
        key: MirageMediaPacketKey,
        direction: MirageMediaDirection
    ) throws -> Data {
        try open(
            wirePayload,
            key: key.symmetricKey,
            nonce: audioNonce(for: header, direction: direction)
        )
    }

    package static func videoNonceInputBytes(
        for header: MirageWire.FrameHeader,
        direction: MirageMediaDirection
    ) -> Data {
        var nonce = [UInt8](repeating: 0, count: 12)
        nonce[0] = 1
        nonce[1] = direction.rawValue
        nonce[2] = 1
        nonce[3] = UInt8(truncatingIfNeeded: header.epoch)
        writeUInt16LittleEndian(header.streamID, into: &nonce, at: 4)
        writeUInt32LittleEndian(header.sequenceNumber, into: &nonce, at: 6)
        writeUInt16LittleEndian(header.fragmentIndex, into: &nonce, at: 10)
        return Data(nonce)
    }

    package static func audioNonceInputBytes(
        for header: MirageWire.AudioPacketHeader,
        direction: MirageMediaDirection
    ) -> Data {
        var nonce = [UInt8](repeating: 0, count: 12)
        nonce[0] = 1
        nonce[1] = direction.rawValue
        nonce[2] = 2
        nonce[3] = 0
        writeUInt16LittleEndian(header.streamID, into: &nonce, at: 4)
        writeUInt32LittleEndian(header.sequenceNumber, into: &nonce, at: 6)
        writeUInt16LittleEndian(header.fragmentIndex, into: &nonce, at: 10)
        return Data(nonce)
    }

    package static func mosaicVideoNonceInputBytes(
        for header: MirageWire.MirageMosaicPacketHeader,
        direction: MirageMediaDirection
    ) -> Data {
        var nonce = [UInt8](repeating: 0, count: 12)
        nonce[0] = 1
        nonce[1] = direction.rawValue
        nonce[2] = 3
        nonce[3] = UInt8(truncatingIfNeeded: header.tilePlanEpoch ^ header.mediaEpoch)
        writeUInt16LittleEndian(header.streamID, into: &nonce, at: 4)
        writeUInt32LittleEndian(header.packetSequence, into: &nonce, at: 6)
        writeUInt16LittleEndian(header.fragmentIndex, into: &nonce, at: 10)
        return Data(nonce)
    }

    package static func encryptClipboardPayload(
        _ plaintext: Data,
        context: MirageMediaSecurityContext
    ) throws -> Data {
        let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: context.sessionKey))
        guard let combined = sealed.combined else {
            throw MirageMediaSecurityError.encryptFailed
        }
        return combined
    }

    package static func decryptClipboardPayload<Payload: DataProtocol>(
        _ encryptedPayload: Payload,
        context: MirageMediaSecurityContext
    ) throws -> Data {
        let combined = Data(encryptedPayload)
        let box: AES.GCM.SealedBox
        do {
            box = try AES.GCM.SealedBox(combined: combined)
        } catch {
            throw MirageMediaSecurityError.invalidEncryptedPayloadLength
        }

        let plaintextData: Data
        do {
            plaintextData = try AES.GCM.open(box, using: SymmetricKey(data: context.sessionKey))
        } catch {
            throw MirageMediaSecurityError.decryptFailed
        }

        return plaintextData
    }

    private static func seal(
        _ plaintext: UnsafeRawBufferPointer,
        key: SymmetricKey,
        nonce: AES.GCM.Nonce
    ) throws -> Data {
        let sealed = try AES.GCM.seal(dataView(plaintext), using: key, nonce: nonce)
        var payload = Data()
        payload.reserveCapacity(sealed.ciphertext.count + sealed.tag.count)
        payload.append(sealed.ciphertext)
        payload.append(sealed.tag)
        return payload
    }

    private static func open<Payload: DataProtocol>(
        _ wirePayload: Payload,
        key: SymmetricKey,
        nonce: AES.GCM.Nonce
    ) throws -> Data {
        guard wirePayload.count >= authTagLength else {
            throw MirageMediaSecurityError.invalidEncryptedPayloadLength
        }
        let ciphertextCount = wirePayload.count - authTagLength
        let ciphertext = wirePayload.prefix(ciphertextCount)
        let tag = wirePayload.suffix(authTagLength)
        let box = try AES.GCM.SealedBox(
            nonce: nonce,
            ciphertext: Data(ciphertext),
            tag: Data(tag)
        )
        do {
            return try AES.GCM.open(box, using: key)
        } catch {
            throw MirageMediaSecurityError.decryptFailed
        }
    }

    private static func videoNonce(
        for header: MirageWire.FrameHeader,
        direction: MirageMediaDirection
    ) throws -> AES.GCM.Nonce {
        try nonceFromBytes(videoNonceInputBytes(for: header, direction: direction))
    }

    private static func audioNonce(
        for header: MirageWire.AudioPacketHeader,
        direction: MirageMediaDirection
    ) throws -> AES.GCM.Nonce {
        try nonceFromBytes(audioNonceInputBytes(for: header, direction: direction))
    }

    private static func mosaicVideoNonce(
        for header: MirageWire.MirageMosaicPacketHeader,
        direction: MirageMediaDirection
    ) throws -> AES.GCM.Nonce {
        try nonceFromBytes(mosaicVideoNonceInputBytes(for: header, direction: direction))
    }

    private static func nonceFromBytes<Bytes: DataProtocol>(_ bytes: Bytes) throws -> AES.GCM.Nonce {
        do {
            return try AES.GCM.Nonce(data: Data(bytes))
        } catch {
            throw MirageMediaSecurityError.invalidNonce
        }
    }

    private static func writeUInt16LittleEndian(_ value: UInt16, into bytes: inout [UInt8], at offset: Int) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    private static func writeUInt32LittleEndian(_ value: UInt32, into bytes: inout [UInt8], at offset: Int) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        bytes[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }

    private static func dataView(_ buffer: UnsafeRawBufferPointer) -> Data {
        guard !buffer.isEmpty, let baseAddress = buffer.baseAddress else { return Data() }
        return Data(
            bytesNoCopy: UnsafeMutableRawPointer(mutating: baseAddress),
            count: buffer.count,
            deallocator: .none
        )
    }

    private static func derivationSalt(
        hostID: UUID,
        clientID: UUID,
        hostKeyID: String,
        clientKeyID: String,
        hostNonce: String,
        clientNonce: String
    ) -> Data {
        let canonical = [
            ("clientID", clientID.uuidString.lowercased()),
            ("clientKeyID", clientKeyID),
            ("clientNonce", clientNonce),
            ("hostID", hostID.uuidString.lowercased()),
            ("hostKeyID", hostKeyID),
            ("hostNonce", hostNonce),
            ("type", derivationSaltType),
        ]
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: "\n")
        return Data(SHA256.hash(data: Data(canonical.utf8)))
    }
}
