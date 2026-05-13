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

/// Fully assembled encoded audio frame ready for decode or playback scheduling.
struct AudioEncodedFrame {
    let frameNumber: UInt32
    let timestampNs: UInt64
    let codec: MirageAudioCodec
    let sampleRate: Int
    let channelCount: Int
    let samplesPerFrame: Int
    let payload: Data
}

/// Reassembles fragmented audio packets and releases frames once startup buffering is satisfied.
actor AudioJitterBuffer {
    /// Maximum age for incomplete fragmented audio frames before they are discarded.
    private static let pendingTimeoutSeconds: CFAbsoluteTime = 1.0

    /// Partial encoded frame waiting for all advertised fragments.
    private struct PendingFrame {
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
    private var pendingFrames: [UInt32: PendingFrame] = [:]
    private var readyFrames: [AudioEncodedFrame] = []
    private var hasStartedPlayback = false
    private var lastEmittedTimestampNs: UInt64?
    private var lastEmittedFrameNumber: UInt32?
    private var lateDropCount: UInt64 = 0
    private var lastLateDropLogTime: CFAbsoluteTime = 0

    init(startupBufferSeconds: Double = 0.150) {
        self.startupBufferSeconds = max(0, startupBufferSeconds)
    }

    func reset() {
        pendingFrames.removeAll()
        readyFrames.removeAll()
        hasStartedPlayback = false
        lastEmittedTimestampNs = nil
        lastEmittedFrameNumber = nil
    }

    func ingest(header: AudioPacketHeader, payload: Data) -> [AudioEncodedFrame] {
        if header.flags.contains(.discontinuity) { clearQueuedFramesForDiscontinuity() }

        let fragmentCount = max(1, Int(header.fragmentCount))
        let fragmentIndex = Int(header.fragmentIndex)
        guard fragmentIndex >= 0, fragmentIndex < fragmentCount else { return [] }

        let now = CFAbsoluteTimeGetCurrent()

        var pending = pendingFrames[header.frameNumber] ?? PendingFrame(
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
                frameNumber: pending.frameNumber,
                timestampNs: pending.timestampNs,
                codec: pending.codec,
                sampleRate: max(1, pending.sampleRate),
                channelCount: max(1, pending.channelCount),
                samplesPerFrame: max(1, pending.samplesPerFrame),
                payload: encodedPayload
            )
            if hasStartedPlayback, isLateFrame(frame) {
                lateDropCount &+= 1
                logLateDropsIfNeeded()
            } else {
                readyFrames.append(frame)
                readyFrames.sort { lhs, rhs in
                    if lhs.timestampNs == rhs.timestampNs { return lhs.frameNumber < rhs.frameNumber }
                    return lhs.timestampNs < rhs.timestampNs
                }
            }
            pendingFrames.removeValue(forKey: pending.frameNumber)
        }

        cleanupStalePendingFrames(now: now)
        return flushPlayableFrames()
    }

    private func clearQueuedFramesForDiscontinuity() {
        pendingFrames.removeAll()
        readyFrames.removeAll()
        lastEmittedTimestampNs = nil
        lastEmittedFrameNumber = nil
    }

    private func flushPlayableFrames() -> [AudioEncodedFrame] {
        guard !readyFrames.isEmpty else { return [] }
        if !hasStartedPlayback {
            let bufferedSeconds = readyFrames.reduce(0.0) { partial, frame in
                guard frame.sampleRate > 0 else { return partial }
                return partial + Double(max(0, frame.samplesPerFrame)) / Double(frame.sampleRate)
            }
            guard bufferedSeconds >= startupBufferSeconds else { return [] }
            hasStartedPlayback = true
        }

        let frames = readyFrames.filter { !isLateFrame($0) }
        let droppedCount = readyFrames.count - frames.count
        if droppedCount > 0 {
            lateDropCount &+= UInt64(droppedCount)
            logLateDropsIfNeeded()
        }
        readyFrames.removeAll(keepingCapacity: true)
        for frame in frames {
            lastEmittedTimestampNs = frame.timestampNs
            lastEmittedFrameNumber = frame.frameNumber
        }
        return frames
    }

    private func cleanupStalePendingFrames(now: CFAbsoluteTime) {
        let staleFrameNumbers = pendingFrames.compactMap { frameNumber, frame in
            now - frame.createdAt > Self.pendingTimeoutSeconds ? frameNumber : nil
        }
        for frameNumber in staleFrameNumbers {
            pendingFrames.removeValue(forKey: frameNumber)
        }
    }

    private func isLateFrame(_ frame: AudioEncodedFrame) -> Bool {
        guard let lastEmittedTimestampNs, let lastEmittedFrameNumber else { return false }
        return frame.timestampNs < lastEmittedTimestampNs ||
            (frame.timestampNs == lastEmittedTimestampNs && frame.frameNumber <= lastEmittedFrameNumber)
    }

    private func logLateDropsIfNeeded() {
        let now = CFAbsoluteTimeGetCurrent()
        guard lastLateDropLogTime == 0 || now - lastLateDropLogTime > 2.0 else { return }
        MirageLogger.client("Audio jitter late drop: dropped \(lateDropCount) stale frame(s)")
        lateDropCount = 0
        lastLateDropLogTime = now
    }
}
