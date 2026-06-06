//
//  HostAudioQualityGovernor.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/21/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import CoreFoundation
import Foundation

#if os(macOS)

struct HostAudioQualityGovernor {
    enum ActivityDecision: Equatable {
        case send(peak: Float)
        case gated(peak: Float)
    }

    private enum PressureReason: String {
        case queueDrop = "queue-drop"
        case queueBacklog = "queue-backlog"
        case transportBackpressure = "transport-backpressure"
        case receiverBacklog = "receiver-backlog"
        case recovery = "recovery"
    }

    private static let silenceThreshold: Float = 0.0005
    private static let silenceGateDelaySeconds = 0.450
    private static let activityHangoverSeconds = 0.180

    private(set) var profile: ResolvedAudioStreamProfile?
    private var configuration: MirageMedia.MirageAudioConfiguration
    private var transportPathKind: MirageCore.MirageNetworkPathKind
    private var mediaPathProfile: MirageMedia.MirageMediaPathProfile
    private var lastPressureTime: CFAbsoluteTime = 0
    private var lastReductionTime: CFAbsoluteTime = 0
    private var lastRecoveryTime: CFAbsoluteTime = 0
    private var lastLogTime: CFAbsoluteTime = 0
    private var silentDurationSeconds: Double = 0
    private var hangoverSecondsRemaining: Double = 0
    private var isActivityGated = false
    private var gatedBufferCount: UInt64 = 0

    init(
        configuration: MirageMedia.MirageAudioConfiguration,
        transportPathKind: MirageCore.MirageNetworkPathKind = .unknown,
        mediaPathProfile: MirageMedia.MirageMediaPathProfile = .unknown
    ) {
        self.configuration = configuration
        self.transportPathKind = transportPathKind
        self.mediaPathProfile = mediaPathProfile
        profile = Self.resolveProfile(
            configuration: configuration,
            transportPathKind: transportPathKind,
            mediaPathProfile: mediaPathProfile
        )
    }

    @discardableResult
    mutating func updateConfiguration(
        _ configuration: MirageMedia.MirageAudioConfiguration,
        transportPathKind: MirageCore.MirageNetworkPathKind? = nil,
        mediaPathProfile: MirageMedia.MirageMediaPathProfile? = nil
    ) -> ResolvedAudioStreamProfile? {
        self.configuration = configuration
        if let transportPathKind {
            self.transportPathKind = transportPathKind
        }
        if let mediaPathProfile {
            self.mediaPathProfile = mediaPathProfile
        }
        profile = Self.resolveProfile(
            configuration: configuration,
            transportPathKind: self.transportPathKind,
            mediaPathProfile: self.mediaPathProfile
        )
        lastPressureTime = 0
        lastReductionTime = 0
        lastRecoveryTime = 0
        silentDurationSeconds = 0
        hangoverSecondsRemaining = 0
        isActivityGated = false
        gatedBufferCount = 0
        return profile
    }

    mutating func activityDecision(for buffer: CapturedAudioBuffer) -> ActivityDecision {
        let peak = buffer.estimatedPeakAmplitude()
        let duration = buffer.durationSeconds
        if peak >= Self.silenceThreshold {
            if isActivityGated {
                MirageLogger.host(
                    "audio activity started peak=\(String(format: "%.4f", peak)) gatedBuffers=\(gatedBufferCount)"
                )
            }
            silentDurationSeconds = 0
            hangoverSecondsRemaining = Self.activityHangoverSeconds
            isActivityGated = false
            gatedBufferCount = 0
            return .send(peak: peak)
        }

        silentDurationSeconds += duration
        if hangoverSecondsRemaining > 0 {
            hangoverSecondsRemaining = max(0, hangoverSecondsRemaining - duration)
            return .send(peak: peak)
        }

        guard silentDurationSeconds >= Self.silenceGateDelaySeconds else {
            return .send(peak: peak)
        }

        gatedBufferCount &+= 1
        if !isActivityGated {
            isActivityGated = true
            MirageLogger.host(
                "audio activity gated silentMs=\(Int((silentDurationSeconds * 1000).rounded()))"
            )
        }
        return .gated(peak: peak)
    }

    mutating func recordQueueState(
        queuedDurationSeconds: Double,
        droppedBuffers: Int,
        maxQueuedDurationSeconds: Double
    ) -> ResolvedAudioStreamProfile? {
        guard canAdapt else { return nil }
        let now = CFAbsoluteTimeGetCurrent()
        if droppedBuffers > 0 {
            return reduce(
                reason: .queueDrop,
                severity: min(4, max(1, droppedBuffers)),
                queuedDurationSeconds: queuedDurationSeconds,
                now: now
            )
        }

        let pressureThreshold = maxQueuedDurationSeconds * 0.70
        guard queuedDurationSeconds > pressureThreshold else { return nil }
        return reduce(
            reason: .queueBacklog,
            severity: 1,
            queuedDurationSeconds: queuedDurationSeconds,
            now: now
        )
    }

    mutating func recordTransportPressure() -> ResolvedAudioStreamProfile? {
        guard canAdapt else { return nil }
        return reduce(
            reason: .transportBackpressure,
            severity: 1,
            queuedDurationSeconds: nil,
            now: CFAbsoluteTimeGetCurrent()
        )
    }

    mutating func recordReceiverFeedback(_ feedback: MirageWire.ReceiverMediaFeedbackMessage) -> ResolvedAudioStreamProfile? {
        guard canAdapt else { return nil }
        var severity = 0
        if feedback.decodeBacklogFrames > 1 || feedback.presentationBacklogFrames > 1 {
            severity += 1
        }
        if (feedback.audioDroppedFrameCount ?? 0) > 0 {
            severity += 1
        }
        if (feedback.audioDroppedFrameCount ?? 0) >= 3 || feedback.audioGateActive == true {
            severity += 1
        }
        if feedback.decodeBacklogFrames > 3 || feedback.presentationBacklogFrames > 3 {
            severity += 1
        }
        if (feedback.presentationStallCount ?? 0) > 0 ||
            (feedback.worstPresentationGapMs ?? 0) > 120 {
            severity += 1
        }
        if feedback.recoveryState != .idle {
            severity += 1
        }
        if feedback.receivedFPS > 0,
           feedback.receivedFPS < Double(feedback.targetFPS) * 0.85 {
            severity += 1
        }
        guard severity > 0 else { return nil }
        return reduce(
            reason: .receiverBacklog,
            severity: min(4, severity),
            queuedDurationSeconds: nil,
            now: CFAbsoluteTimeGetCurrent()
        )
    }

    mutating func recordSuccessfulFrame() -> ResolvedAudioStreamProfile? {
        guard canAdapt,
              let current = profile?.bitrateBps,
              let maximum = profile?.maximumBitrateBps,
              current < maximum else {
            return nil
        }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastPressureTime > 12.0,
              now - lastRecoveryTime > 6.0 else {
            return nil
        }

        let increment = max(8_000, maximum / 20)
        let nextBitrate = min(maximum, current + increment)
        guard nextBitrate > current else { return nil }
        profile = profile?.withBitrate(nextBitrate)
        lastRecoveryTime = now
        logChange(reason: .recovery, bitrateBps: profile?.bitrateBps ?? nextBitrate, queuedDurationSeconds: nil, now: now)
        return profile
    }

    private var canAdapt: Bool {
        configuration.enabled &&
            configuration.quality != .lossless &&
            configuration.adaptiveCompressionEnabled &&
            profile?.bitrateBps != nil
    }

    private mutating func reduce(
        reason: PressureReason,
        severity: Int,
        queuedDurationSeconds: Double?,
        now: CFAbsoluteTime
    ) -> ResolvedAudioStreamProfile? {
        guard let current = profile?.bitrateBps,
              let minimum = profile?.minimumBitrateBps else {
            return nil
        }
        lastPressureTime = now
        guard now - lastReductionTime > 0.75 else { return nil }

        let factor = pow(0.86, Double(max(1, severity)))
        let nextBitrate = max(minimum, AudioEncoder.roundedAACBitrate(Int(Double(current) * factor)))
        guard nextBitrate < current else { return nil }
        profile = profile?.withBitrate(nextBitrate)
        lastReductionTime = now
        logChange(reason: reason, bitrateBps: nextBitrate, queuedDurationSeconds: queuedDurationSeconds, now: now)
        return profile
    }

    private mutating func logChange(
        reason: PressureReason,
        bitrateBps: Int,
        queuedDurationSeconds: Double?,
        now: CFAbsoluteTime
    ) {
        guard now - lastLogTime > 1.0 else { return }
        lastLogTime = now
        let queuedText = queuedDurationSeconds.map {
            " queuedMs=\(Int(($0 * 1000).rounded()))"
        } ?? ""
        MirageLogger.host("Audio quality governor \(reason.rawValue): bitrate=\(bitrateBps)bps\(queuedText)")
    }

    private static func resolveProfile(
        configuration: MirageMedia.MirageAudioConfiguration,
        transportPathKind: MirageCore.MirageNetworkPathKind,
        mediaPathProfile: MirageMedia.MirageMediaPathProfile
    ) -> ResolvedAudioStreamProfile? {
        let profile = ResolvedAudioStreamProfile.resolve(
            configuration: configuration,
            transportPathKind: transportPathKind,
            mediaPathProfile: mediaPathProfile
        )
        if profile?.codec == .pcm16LE, configuration.quality != .lossless {
            MirageLogger.host("Audio profile rejected unexpected PCM for compressed configuration")
            return nil
        }
        return profile
    }
}

#endif
