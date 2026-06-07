//
//  HostAudioCompressionBudgetController.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/28/26.
//
//  Runtime audio compression budget adaptation for host audio streaming.
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

struct HostAudioCompressionBudgetController {
    private enum PressureReason: String {
        case queueDrop = "queue-drop"
        case queueBacklog = "queue-backlog"
        case transportBackpressure = "transport-backpressure"
        case receiverBacklog = "receiver-backlog"
        case recovery = "recovery"
    }

    private var configuration: MirageMedia.MirageAudioConfiguration
    private var transportPathKind: MirageCore.MirageNetworkPathKind
    private var mediaPathProfile: MirageMedia.MirageMediaPathProfile
    private var minimumBitrateBps: Int
    private var maximumBitrateBps: Int
    private(set) var currentBitrateBps: Int?
    private var lastPressureTime: CFAbsoluteTime = 0
    private var lastReductionTime: CFAbsoluteTime = 0
    private var lastRecoveryTime: CFAbsoluteTime = 0
    private var lastLogTime: CFAbsoluteTime = 0

    init(
        configuration: MirageMedia.MirageAudioConfiguration,
        transportPathKind: MirageCore.MirageNetworkPathKind = .unknown,
        mediaPathProfile: MirageMedia.MirageMediaPathProfile = .unknown
    ) {
        self.configuration = configuration
        self.transportPathKind = transportPathKind
        self.mediaPathProfile = mediaPathProfile
        let budget = Self.budgetRange(
            for: configuration,
            transportPathKind: transportPathKind,
            mediaPathProfile: mediaPathProfile
        )
        minimumBitrateBps = budget.minimum
        maximumBitrateBps = budget.maximum
        currentBitrateBps = budget.current
    }

    @discardableResult
    mutating func updateConfiguration(
        _ configuration: MirageMedia.MirageAudioConfiguration,
        transportPathKind: MirageCore.MirageNetworkPathKind? = nil,
        mediaPathProfile: MirageMedia.MirageMediaPathProfile? = nil
    ) -> Int? {
        let previousBitrate = currentBitrateBps
        self.configuration = configuration
        if let transportPathKind {
            self.transportPathKind = transportPathKind
        }
        if let mediaPathProfile {
            self.mediaPathProfile = mediaPathProfile
        }
        let budget = Self.budgetRange(
            for: configuration,
            transportPathKind: self.transportPathKind,
            mediaPathProfile: self.mediaPathProfile
        )
        minimumBitrateBps = budget.minimum
        maximumBitrateBps = budget.maximum
        currentBitrateBps = budget.current
        lastPressureTime = 0
        lastReductionTime = 0
        lastRecoveryTime = 0
        return currentBitrateBps != previousBitrate ? currentBitrateBps : nil
    }

    mutating func recordQueueState(
        queuedDurationSeconds: Double,
        droppedBuffers: Int,
        maxQueuedDurationSeconds: Double
    ) -> Int? {
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

    mutating func recordTransportPressure() -> Int? {
        guard canAdapt else { return nil }
        return reduce(
            reason: .transportBackpressure,
            severity: 1,
            queuedDurationSeconds: nil,
            now: CFAbsoluteTimeGetCurrent()
        )
    }

    mutating func recordReceiverFeedback(_ feedback: MirageWire.ReceiverMediaFeedbackMessage) -> Int? {
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

    mutating func recordSuccessfulFrame() -> Int? {
        guard canAdapt,
              let currentBitrateBps,
              currentBitrateBps < maximumBitrateBps else {
            return nil
        }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastPressureTime > 12.0,
              now - lastRecoveryTime > 6.0 else {
            return nil
        }

        let increment = max(8_000, maximumBitrateBps / 20)
        let nextBitrate = min(maximumBitrateBps, currentBitrateBps + increment)
        guard nextBitrate > currentBitrateBps else { return nil }
        self.currentBitrateBps = AudioEncoder.roundedAACBitrate(nextBitrate)
        lastRecoveryTime = now
        logChange(
            reason: .recovery,
            bitrateBps: self.currentBitrateBps ?? nextBitrate,
            queuedDurationSeconds: nil,
            now: now
        )
        return self.currentBitrateBps
    }

    private var canAdapt: Bool {
        configuration.enabled &&
            configuration.quality != .lossless &&
            configuration.adaptiveCompressionEnabled &&
            currentBitrateBps != nil
    }

    private mutating func reduce(
        reason: PressureReason,
        severity: Int,
        queuedDurationSeconds: Double?,
        now: CFAbsoluteTime
    ) -> Int? {
        guard let currentBitrateBps else { return nil }
        lastPressureTime = now
        guard now - lastReductionTime > 0.75 else { return nil }

        let factor = pow(0.86, Double(max(1, severity)))
        let requestedBitrate = Int(Double(currentBitrateBps) * factor)
        let nextBitrate = max(
            minimumBitrateBps,
            AudioEncoder.roundedAACBitrate(requestedBitrate)
        )
        guard nextBitrate < currentBitrateBps else { return nil }

        self.currentBitrateBps = nextBitrate
        lastReductionTime = now
        logChange(
            reason: reason,
            bitrateBps: nextBitrate,
            queuedDurationSeconds: queuedDurationSeconds,
            now: now
        )
        return nextBitrate
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
        MirageLogger.host(
            "Audio compression budget \(reason.rawValue): bitrate=\(bitrateBps)bps\(queuedText)"
        )
    }

    private static func budgetRange(
        for configuration: MirageMedia.MirageAudioConfiguration,
        transportPathKind: MirageCore.MirageNetworkPathKind,
        mediaPathProfile: MirageMedia.MirageMediaPathProfile
    ) -> (minimum: Int, maximum: Int, current: Int?) {
        guard configuration.enabled,
              configuration.quality != .lossless else {
            return (0, 0, nil)
        }
        if let decision = HostAdaptiveAudioBudgetPolicy.resolve(
            HostAdaptiveAudioBudgetPolicy.Request(
                configuration: configuration,
                transportPathKind: transportPathKind,
                mediaPathProfile: mediaPathProfile
            )
        ) {
            return (
                decision.minimumBitrateFloorBps,
                decision.maximumCeilingBps,
                decision.startupBitrateBps
            )
        }
        let channelCount = configuration.channelLayout.channelCount
        let minimum = AudioEncoder.minimumAACBitrate(channels: channelCount)
        let defaultMaximum = AudioEncoder.aacBitrate(
            quality: configuration.quality,
            channels: channelCount
        )
        let configuredCurrent = configuration.compressedBitrateBps.map {
            max(minimum, min(defaultMaximum, AudioEncoder.roundedAACBitrate($0)))
        } ?? defaultMaximum
        let configuredCeiling = configuration.compressedBitrateCeilingBps.map {
            max(minimum, min(defaultMaximum, AudioEncoder.roundedAACBitrate($0)))
        }
        let maximum = max(configuredCurrent, configuredCeiling ?? configuredCurrent)
        let current = min(configuredCurrent, maximum)
        return (minimum, maximum, current)
    }
}

#endif
