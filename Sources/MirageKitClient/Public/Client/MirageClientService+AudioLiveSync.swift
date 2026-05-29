//
//  MirageClientService+AudioLiveSync.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//
//  Decoded audio buffering and live video sync.
//

import CoreMedia
import Foundation
import MirageKit

@MainActor
extension MirageClientService {
    private static let maxAudioVideoSyncSnapshotAgeSeconds: CFAbsoluteTime = 0.250
    private static let maxAudioVideoHoldSeconds: Double = 0.080
    private static let liveAudioMaxBehindNs: UInt64 = 500_000_000

    /// Buffers decoded audio that arrived before the matching audio stream is fully announced.
    func bufferPendingDecodedAudioFrames(_ decodedFrames: [DecodedPCMFrame], for streamID: StreamID) {
        guard !decodedFrames.isEmpty else { return }
        var frames = pendingDecodedAudioFramesByStreamID[streamID] ?? []
        var duration = pendingDecodedAudioDurationByStreamID[streamID] ?? 0

        for frame in decodedFrames {
            frames.append(frame)
            duration += frame.durationSeconds
        }

        while duration > maxPendingDecodedAudioDuration, !frames.isEmpty {
            duration = max(0, duration - frames.removeFirst().durationSeconds)
        }

        pendingDecodedAudioFramesByStreamID[streamID] = frames
        pendingDecodedAudioDurationByStreamID[streamID] = duration
    }

    /// Keeps only the live tail while playback is gated behind video presentation.
    func bufferPendingDecodedAudioTail(_ decodedFrames: [DecodedPCMFrame], for streamID: StreamID) {
        guard !decodedFrames.isEmpty else { return }
        let existingFrames = pendingDecodedAudioFramesByStreamID[streamID] ?? []
        let tail = LiveAudioSyncPolicy.decide(
            frames: existingFrames + decodedFrames,
            videoState: .waitingForFirstFrame,
            liveTailDurationSeconds: LiveAudioSyncPolicy.defaultLiveTailDurationSeconds
        ).frames
        pendingDecodedAudioFramesByStreamID[streamID] = tail
        pendingDecodedAudioDurationByStreamID[streamID] = tail.reduce(0) { $0 + $1.durationSeconds }
    }

    /// Flushes pending decoded audio through the live sync gate into playback.
    func flushPendingDecodedAudioFrames(
        for streamID: StreamID,
        into audioPlaybackController: AudioPlaybackController
    ) {
        guard let frames = pendingDecodedAudioFramesByStreamID.removeValue(forKey: streamID),
              !frames.isEmpty else {
            pendingDecodedAudioDurationByStreamID.removeValue(forKey: streamID)
            return
        }

        pendingDecodedAudioDurationByStreamID.removeValue(forKey: streamID)
        let decision = liveAudioDecision(for: frames, streamID: streamID)
        applyAudioLiveSyncDiagnostics(decision, streamID: streamID)
        guard !decision.shouldGatePlayback else {
            bufferPendingDecodedAudioTail(decision.frames, for: streamID)
            return
        }
        audioPlaybackController.setRuntimeExtraDelay(seconds: decision.runtimeExtraDelaySeconds)
        logAudioAheadIfNeeded(
            streamID: streamID,
            nextFrame: decision.frames.first,
            delay: decision.runtimeExtraDelaySeconds
        )
        for frame in decision.frames {
            audioPlaybackController.enqueue(frame)
        }
    }

    /// Clears pending decoded audio for one stream or for all streams.
    func resetPendingDecodedAudioFrames(for streamID: StreamID? = nil) {
        if let streamID {
            pendingDecodedAudioFramesByStreamID.removeValue(forKey: streamID)
            pendingDecodedAudioDurationByStreamID.removeValue(forKey: streamID)
            audioFeedbackDroppedFrameCountByStreamID.removeValue(forKey: streamID)
        } else {
            pendingDecodedAudioFramesByStreamID.removeAll()
            pendingDecodedAudioDurationByStreamID.removeAll()
            audioFeedbackDroppedFrameCountByStreamID.removeAll()
        }
    }

    func liveAudioDecision(
        for frames: [DecodedPCMFrame],
        streamID: StreamID
    ) -> LiveAudioSyncPolicy.Decision {
        LiveAudioSyncPolicy.decide(
            frames: frames,
            videoState: liveAudioVideoState(for: streamID),
            maxBehindNs: Self.liveAudioMaxBehindNs,
            liveTailDurationSeconds: LiveAudioSyncPolicy.defaultLiveTailDurationSeconds,
            maxHoldSeconds: Self.maxAudioVideoHoldSeconds
        )
    }

    private func liveAudioVideoState(for streamID: StreamID) -> LiveAudioSyncPolicy.VideoState {
        if let timestampNs = freshVideoTimestampNs(for: streamID) {
            return .fresh(timestampNs: timestampNs)
        }

        if streamHasPresentedVideoFrame(streamID) {
            return .staleAfterPresentation
        }

        if activeMediaStreams["video/\(streamID)"] != nil ||
            sessionStore.sessionByStreamID(streamID) != nil ||
            sessionStore.sessionByMediaStreamID(streamID) != nil {
            return .waitingForFirstFrame
        }

        return .unavailable
    }

    private func freshVideoTimestampNs(for streamID: StreamID) -> UInt64? {
        let snapshot = MirageRenderStreamStore.shared.submissionSnapshot(for: streamID)
        guard snapshot.sequence > 0 else { return nil }
        let ageSeconds = CFAbsoluteTimeGetCurrent() - snapshot.submittedTime
        guard ageSeconds >= 0,
              ageSeconds <= Self.maxAudioVideoSyncSnapshotAgeSeconds else {
            return nil
        }
        return Self.nanoseconds(from: snapshot.remotePresentationTime)
    }

    private func streamHasPresentedVideoFrame(_ streamID: StreamID) -> Bool {
        sessionStore.sessionByStreamID(streamID)?.hasPresentedFrame == true ||
            sessionStore.sessionByMediaStreamID(streamID)?.hasPresentedFrame == true ||
            MirageRenderStreamStore.shared.submissionSnapshot(for: streamID).sequence > 0
    }

    func applyAudioLiveSyncDiagnostics(
        _ decision: LiveAudioSyncPolicy.Decision,
        streamID: StreamID
    ) {
        guard decision.droppedCount > 0 else { return }
        audioSyncDropCount &+= UInt64(decision.droppedCount)
        audioFeedbackDroppedFrameCountByStreamID[streamID, default: 0] &+= UInt64(decision.droppedCount)
        logAudioSyncDropsIfNeeded(streamID: streamID, reason: decision.reason)
    }

    private func logAudioSyncDropsIfNeeded(streamID: StreamID, reason: String?) {
        guard MirageSteadyStateDiagnostics.isEnabled else {
            audioSyncDropCount = 0
            return
        }
        let now = CFAbsoluteTimeGetCurrent()
        guard lastAudioSyncDropLogTime == 0 || now - lastAudioSyncDropLogTime > 2.0 else { return }
        let reasonText = reason.map { ", reason=\($0)" } ?? ""
        MirageLogger.client(
            "Audio sync drop: stream=\(streamID), dropped=\(audioSyncDropCount) stale decoded frame(s)\(reasonText)"
        )
        audioSyncDropCount = 0
        lastAudioSyncDropLogTime = now
    }

    func logAudioAheadIfNeeded(streamID: StreamID, nextFrame: DecodedPCMFrame?, delay: Double) {
        guard MirageSteadyStateDiagnostics.isEnabled else { return }
        guard let videoTimestampNs = freshVideoTimestampNs(for: streamID),
              let nextFrame,
              nextFrame.timestampNs > videoTimestampNs else {
            return
        }
        let aheadSeconds = Double(nextFrame.timestampNs - videoTimestampNs) / 1_000_000_000
        let now = CFAbsoluteTimeGetCurrent()
        guard delay > 0.001, lastAudioSyncAheadLogTime == 0 || now - lastAudioSyncAheadLogTime > 2.0 else {
            return
        }
        MirageLogger.client(
            "Audio sync hold: stream=\(streamID), aheadMs=\(Int((aheadSeconds * 1000).rounded())), delayMs=\(Int((delay * 1000).rounded()))"
        )
        lastAudioSyncAheadLogTime = now
    }

    private nonisolated static func nanoseconds(from time: CMTime) -> UInt64? {
        guard time.isValid else { return nil }
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite, seconds >= 0 else { return nil }
        return UInt64(seconds * 1_000_000_000)
    }
}
