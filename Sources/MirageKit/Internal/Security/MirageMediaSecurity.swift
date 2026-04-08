//
//  MirageMediaSecurity.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/11/26.
//
//  Media session key derivation, registration authentication, and packet AEAD helpers.
//

import CryptoKit
import Foundation

package enum MirageMediaDirection: UInt8, Sendable {
    case hostToClient = 1
    case clientToHost = 2
}

package struct MirageMediaPacketKey {
    fileprivate let symmetricKey: SymmetricKey

    package init(sessionKeyData: Data) {
        symmetricKey = SymmetricKey(data: sessionKeyData)
    }
}

package struct MirageMediaSecurityContext: Sendable {
    package let sessionKey: Data
    package let udpRegistrationToken: Data

    package init(sessionKey: Data, udpRegistrationToken: Data) {
        self.sessionKey = sessionKey
        self.udpRegistrationToken = udpRegistrationToken
    }
}

package enum MirageMediaSecurityError: Error {
    case invalidRegistrationTokenLength
    case invalidEncryptedPayloadLength
    case invalidNonce
    case invalidClipboardTextEncoding
    case encryptFailed
    case decryptFailed
}

package enum MirageMediaSecurity {
    package static let sessionKeyLength = 32
    package static let registrationTokenLength = 32
    package static let authTagLength = mirageMediaAuthTagSize

    package static func makePacketKey(context: MirageMediaSecurityContext) -> MirageMediaPacketKey {
        makePacketKey(sessionKeyData: context.sessionKey)
    }

    package static func makePacketKey(sessionKeyData: Data) -> MirageMediaPacketKey {
        MirageMediaPacketKey(sessionKeyData: sessionKeyData)
    }

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
        udpRegistrationToken: Data
    ) throws -> MirageMediaSecurityContext {
        guard udpRegistrationToken.count == registrationTokenLength else {
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
            sharedInfo: Data("mirage-media-session-v1".utf8),
            outputByteCount: sessionKeyLength
        )
        return MirageMediaSecurityContext(
            sessionKey: key,
            udpRegistrationToken: udpRegistrationToken
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
        udpRegistrationToken: Data
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
            udpRegistrationToken: udpRegistrationToken
        )
    }

    package static func encryptVideoPayload(
        _ plaintext: Data,
        header: FrameHeader,
        context: MirageMediaSecurityContext,
        direction: MirageMediaDirection
    ) throws -> Data {
        let key = makePacketKey(context: context)
        return try plaintext.withUnsafeBytes { plaintextBytes in
            try encryptVideoPayload(
                plaintextBytes,
                header: header,
                key: key,
                direction: direction
            )
        }
    }

    package static func encryptVideoPayload(
        _ plaintext: UnsafeRawBufferPointer,
        header: FrameHeader,
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
        header: FrameHeader,
        context: MirageMediaSecurityContext,
        direction: MirageMediaDirection
    ) throws -> Data {
        try decryptVideoPayload(
            wirePayload,
            header: header,
            key: makePacketKey(context: context),
            direction: direction
        )
    }

    package static func decryptVideoPayload<Payload: DataProtocol>(
        _ wirePayload: Payload,
        header: FrameHeader,
        key: MirageMediaPacketKey,
        direction: MirageMediaDirection
    ) throws -> Data {
        try open(
            wirePayload,
            key: key.symmetricKey,
            nonce: videoNonce(for: header, direction: direction)
        )
    }

    package static func encryptAudioPayload(
        _ plaintext: Data,
        header: AudioPacketHeader,
        context: MirageMediaSecurityContext,
        direction: MirageMediaDirection
    ) throws -> Data {
        let key = makePacketKey(context: context)
        return try plaintext.withUnsafeBytes { plaintextBytes in
            try encryptAudioPayload(
                plaintextBytes,
                header: header,
                key: key,
                direction: direction
            )
        }
    }

    package static func encryptAudioPayload(
        _ plaintext: UnsafeRawBufferPointer,
        header: AudioPacketHeader,
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
        header: AudioPacketHeader,
        context: MirageMediaSecurityContext,
        direction: MirageMediaDirection
    ) throws -> Data {
        try decryptAudioPayload(
            wirePayload,
            header: header,
            key: makePacketKey(context: context),
            direction: direction
        )
    }

    package static func decryptAudioPayload<Payload: DataProtocol>(
        _ wirePayload: Payload,
        header: AudioPacketHeader,
        key: MirageMediaPacketKey,
        direction: MirageMediaDirection
    ) throws -> Data {
        try open(
            wirePayload,
            key: key.symmetricKey,
            nonce: audioNonce(for: header, direction: direction)
        )
    }

    package static func encryptClipboardText(
        _ plaintext: String,
        context: MirageMediaSecurityContext
    ) throws -> Data {
        guard let plaintextData = plaintext.data(using: .utf8) else {
            throw MirageMediaSecurityError.invalidClipboardTextEncoding
        }

        let sealed = try AES.GCM.seal(plaintextData, using: SymmetricKey(data: context.sessionKey))
        guard let combined = sealed.combined else {
            throw MirageMediaSecurityError.encryptFailed
        }
        return combined
    }

    package static func decryptClipboardText<Payload: DataProtocol>(
        _ encryptedText: Payload,
        context: MirageMediaSecurityContext
    ) throws -> String {
        let combined = Data(encryptedText)
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

        guard let plaintext = String(data: plaintextData, encoding: .utf8) else {
            throw MirageMediaSecurityError.invalidClipboardTextEncoding
        }
        return plaintext
    }

    package static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        let maxLength = max(lhs.count, rhs.count)
        var diff = lhs.count ^ rhs.count
        for index in 0 ..< maxLength {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            diff |= Int(left ^ right)
        }
        return diff == 0
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
        for header: FrameHeader,
        direction: MirageMediaDirection
    ) throws -> AES.GCM.Nonce {
        var nonce = [UInt8](repeating: 0, count: 12)
        nonce[0] = 1
        nonce[1] = direction.rawValue
        nonce[2] = 1
        nonce[3] = UInt8(truncatingIfNeeded: header.epoch)
        writeUInt16LittleEndian(header.streamID, into: &nonce, at: 4)
        writeUInt32LittleEndian(header.sequenceNumber, into: &nonce, at: 6)
        writeUInt16LittleEndian(header.fragmentIndex, into: &nonce, at: 10)
        return try nonceFromBytes(nonce)
    }

    private static func audioNonce(
        for header: AudioPacketHeader,
        direction: MirageMediaDirection
    ) throws -> AES.GCM.Nonce {
        var nonce = [UInt8](repeating: 0, count: 12)
        nonce[0] = 1
        nonce[1] = direction.rawValue
        nonce[2] = 2
        nonce[3] = 0
        writeUInt16LittleEndian(header.streamID, into: &nonce, at: 4)
        writeUInt32LittleEndian(header.sequenceNumber, into: &nonce, at: 6)
        writeUInt16LittleEndian(header.fragmentIndex, into: &nonce, at: 10)
        return try nonceFromBytes(nonce)
    }

    private static func nonceFromBytes(_ bytes: [UInt8]) throws -> AES.GCM.Nonce {
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
        guard buffer.count > 0, let baseAddress = buffer.baseAddress else { return Data() }
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
            ("type", "media-key-derivation-v1"),
        ]
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: "\n")
        return Data(SHA256.hash(data: Data(canonical.utf8)))
    }
}
