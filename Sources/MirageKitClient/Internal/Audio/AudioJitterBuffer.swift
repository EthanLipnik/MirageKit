//
//  AudioJitterBuffer.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/6/26.
//
//  Timestamp-aware audio frame assembly with startup buffering.
//

import Foundation
import MirageKit

struct AudioEncodedFrame: Sendable {
    let streamID: StreamID
    let frameNumber: UInt32
    let timestampNs: UInt64
    let codec: MirageAudioCodec
    let sampleRate: Int
    let channelCount: Int
    let samplesPerFrame: Int
    let payload: Data
}

actor AudioJitterBuffer {
    private struct PendingFrame {
        let streamID: StreamID
        let frameNumber: UInt32
        let timestampNs: UInt64
        let codec: MirageAudioCodec
        let sampleRate: Int
        let channelCount: Int
        let samplesPerFrame: Int
        let frameByteCount: Int
        let createdAt: CFAbsoluteTime
        var fragments: [Data?]
        var receivedCount: Int
    }

    private let startupBufferSeconds: Double
    private let pendingTimeoutSeconds: CFAbsoluteTime = 1.0
    private var pendingFrames: [UInt32: PendingFrame] = [:]
    private var readyFrames: [AudioEncodedFrame] = []
    private var hasStartedPlayback = false

    init(startupBufferSeconds: Double = 0.150) {
        self.startupBufferSeconds = max(0, startupBufferSeconds)
    }

    func reset() {
        pendingFrames.removeAll()
        readyFrames.removeAll()
        hasStartedPlayback = false
    }

    @discardableResult
    func ingest(header: AudioPacketHeader, payload: Data) -> [AudioEncodedFrame] {
        if header.flags.contains(.discontinuity) { reset() }

        let fragmentCount = max(1, Int(header.fragmentCount))
        let fragmentIndex = Int(header.fragmentIndex)
        guard fragmentIndex >= 0, fragmentIndex < fragmentCount else { return [] }

        let now = CFAbsoluteTimeGetCurrent()

        var pending = pendingFrames[header.frameNumber] ?? PendingFrame(
            streamID: header.streamID,
            frameNumber: header.frameNumber,
            timestampNs: header.timestamp,
            codec: header.codec,
            sampleRate: Int(header.sampleRate),
            channelCount: Int(header.channelCount),
            samplesPerFrame: Int(header.samplesPerFrame),
            frameByteCount: max(0, Int(header.frameByteCount)),
            createdAt: now,
            fragments: Array(repeating: nil, count: fragmentCount),
            receivedCount: 0
        )

        if pending.fragments.count != fragmentCount {
            pending.fragments = Array(repeating: nil, count: fragmentCount)
            pending.receivedCount = 0
        }

        if pending.fragments[fragmentIndex] == nil {
            pending.fragments[fragmentIndex] = payload
            pending.receivedCount += 1
        }

        pendingFrames[header.frameNumber] = pending

        if pending.receivedCount == pending.fragments.count {
            let totalCapacity = pending.frameByteCount > 0 ? pending.frameByteCount : payload.count * fragmentCount
            var encodedPayload = Data(capacity: max(1, totalCapacity))
            for fragment in pending.fragments {
                guard let fragment else { continue }
                encodedPayload.append(fragment)
            }
            if pending.frameByteCount > 0, encodedPayload.count > pending.frameByteCount {
                encodedPayload = Data(encodedPayload.prefix(pending.frameByteCount))
            }

            let frame = AudioEncodedFrame(
                streamID: pending.streamID,
                frameNumber: pending.frameNumber,
                timestampNs: pending.timestampNs,
                codec: pending.codec,
                sampleRate: max(1, pending.sampleRate),
                channelCount: max(1, pending.channelCount),
                samplesPerFrame: max(1, pending.samplesPerFrame),
                payload: encodedPayload
            )
            readyFrames.append(frame)
            readyFrames.sort { lhs, rhs in
                if lhs.timestampNs == rhs.timestampNs { return lhs.frameNumber < rhs.frameNumber }
                return lhs.timestampNs < rhs.timestampNs
            }
            pendingFrames.removeValue(forKey: pending.frameNumber)
        }

        cleanupStalePendingFrames(now: now)
        return flushPlayableFrames()
    }

    private func flushPlayableFrames() -> [AudioEncodedFrame] {
        guard !readyFrames.isEmpty else { return [] }
        if !hasStartedPlayback {
            let bufferedSeconds = readyFrames.reduce(0.0) { partial, frame in
                partial + durationSeconds(samples: frame.samplesPerFrame, sampleRate: frame.sampleRate)
            }
            guard bufferedSeconds >= startupBufferSeconds else { return [] }
            hasStartedPlayback = true
        }

        let frames = readyFrames
        readyFrames.removeAll(keepingCapacity: true)
        return frames
    }

    private func cleanupStalePendingFrames(now: CFAbsoluteTime) {
        let staleFrameNumbers = pendingFrames.compactMap { frameNumber, frame in
            now - frame.createdAt > pendingTimeoutSeconds ? frameNumber : nil
        }
        for frameNumber in staleFrameNumbers {
            pendingFrames.removeValue(forKey: frameNumber)
        }
    }

    private func durationSeconds(samples: Int, sampleRate: Int) -> Double {
        guard sampleRate > 0 else { return 0 }
        return Double(max(0, samples)) / Double(sampleRate)
    }
}

