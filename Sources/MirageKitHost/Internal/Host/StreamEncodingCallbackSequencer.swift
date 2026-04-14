//
//  StreamEncodingCallbackSequencer.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/14/26.
//

import Foundation

#if os(macOS)

/// Serializes per-frame numbering for encoded-frame callbacks that may arrive concurrently.
final class StreamEncodingCallbackSequencer: @unchecked Sendable {
    struct Reservation: Sendable {
        let frameNumber: UInt32
        let sequenceNumberStart: UInt32
        let totalFragments: Int
        let wireBytes: Int
        let shouldLogPFrameDiagnostic: Bool
    }

    private struct State {
        var nextFrameNumber: UInt32 = 0
        var nextSequenceNumber: UInt32 = 0
        var pFrameDiagnosticCounter: UInt32 = 0
    }

    private let state = Locked(State())

    func reserve(
        frameByteCount: Int,
        maxPayloadSize: Int,
        fecBlockSize: Int,
        isKeyframe: Bool
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

            let shouldLogPFrameDiagnostic: Bool
            if isKeyframe {
                shouldLogPFrameDiagnostic = false
            } else {
                state.pFrameDiagnosticCounter &+= 1
                shouldLogPFrameDiagnostic = state.pFrameDiagnosticCounter % 60 == 1
            }

            state.nextFrameNumber &+= 1
            if totalFragments > 0 {
                state.nextSequenceNumber &+= UInt32(totalFragments)
            }

            return Reservation(
                frameNumber: frameNumber,
                sequenceNumberStart: sequenceNumberStart,
                totalFragments: totalFragments,
                wireBytes: wireBytes,
                shouldLogPFrameDiagnostic: shouldLogPFrameDiagnostic
            )
        }
    }
}

#endif
