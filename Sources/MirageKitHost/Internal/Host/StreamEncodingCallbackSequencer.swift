//
//  StreamEncodingCallbackSequencer.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/14/26.
//

import Foundation

#if os(macOS)

/// Serializes host frame and packet sequence numbering for encoded-frame callbacks that may arrive concurrently.
final class StreamEncodingCallbackSequencer: @unchecked Sendable {
    /// Numbering and capacity reserved for packetizing one encoded frame.
    struct Reservation: Sendable {
        /// Monotonic host frame number assigned to the encoded frame.
        let frameNumber: UInt32
        /// First packet sequence number reserved for the frame's data fragments and any FEC parity fragments.
        let sequenceNumberStart: UInt32
        /// Encoded frame bytes plus the payload capacity reserved for parity fragments.
        let wireBytes: Int
    }

    private struct State {
        var nextFrameNumber: UInt32 = 0
        var nextSequenceNumber: UInt32 = 0
    }

    private let state = Locked(State())

    /// Reserves a frame number and the packet sequence range needed before packetization.
    ///
    /// Zero-byte callbacks still consume a frame number but reserve no packet sequence numbers.
    func reserve(
        frameByteCount: Int,
        maxPayloadSize: Int,
        fecBlockSize: Int
    ) -> Reservation {
        state.withLock { state in
            let frameNumber = state.nextFrameNumber
            let sequenceNumberStart = state.nextSequenceNumber

            let payloadSize = max(1, maxPayloadSize)
            let dataFragments = frameByteCount > 0
                ? (frameByteCount + payloadSize - 1) / payloadSize
                : 0
            let parityFragments = fecBlockSize > 1
                ? (dataFragments + fecBlockSize - 1) / fecBlockSize
                : 0
            let totalFragments = dataFragments + parityFragments
            let wireBytes = frameByteCount + parityFragments * payloadSize

            state.nextFrameNumber &+= 1
            if totalFragments > 0 {
                state.nextSequenceNumber &+= UInt32(totalFragments)
            }

            return Reservation(
                frameNumber: frameNumber,
                sequenceNumberStart: sequenceNumberStart,
                wireBytes: wireBytes
            )
        }
    }
}

#endif
