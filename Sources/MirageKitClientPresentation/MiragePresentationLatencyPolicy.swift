//
//  MiragePresentationLatencyPolicy.swift
//  MirageKitClientPresentation
//
//  Created by Ethan Lipnik on 6/5/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageMedia
import MirageWire
import Foundation

/// Local client presentation bounds for a stream latency mode.
///
/// This policy only controls decoded-frame playout on the client. It must not
/// be used to change host capture cadence, virtual display refresh, stream
/// scale, or encoded resolution.
package struct MiragePresentationLatencyPolicy: Equatable, Sendable {
    package let latencyMode: MirageMedia.MirageStreamLatencyMode
    package let sourceFPS: Int
    package let displayFPS: Int
    package let transportPathKind: MirageCore.MirageNetworkPathKind
    package let mediaPathProfile: MirageMedia.MirageMediaPathProfile
    package let hasRecentInteraction: Bool
    package let lastInteractionAgeSeconds: CFTimeInterval?
    package let awdlReceiverPlayoutDelayTargetMs: Double?

    package init(
        latencyMode: MirageMedia.MirageStreamLatencyMode,
        sourceFPS: Int,
        displayFPS: Int,
        transportPathKind: MirageCore.MirageNetworkPathKind = .unknown,
        mediaPathProfile: MirageMedia.MirageMediaPathProfile? = nil,
        hasRecentInteraction: Bool = false,
        lastInteractionAgeSeconds: CFTimeInterval? = nil,
        awdlReceiverPlayoutDelayTargetMs: Double? = nil
    ) {
        let explicitMediaPathProfile: MirageMedia.MirageMediaPathProfile?
        if mediaPathProfile == .unknown, transportPathKind == .awdl || latencyMode != .smoothest {
            explicitMediaPathProfile = nil
        } else {
            explicitMediaPathProfile = mediaPathProfile
        }
        let resolvedMediaPathProfile = MirageMedia.MirageMediaPathProfile.resolveRealtimeProfile(
            pathKind: transportPathKind,
            mediaPathProfile: explicitMediaPathProfile
        )
        self.latencyMode = MirageAwdlMediaController.fixedLatencyMode(
            requestedLatencyMode: latencyMode,
            mediaPathProfile: resolvedMediaPathProfile
        )
        self.sourceFPS = MirageRenderModePolicy.normalizedTargetFPS(sourceFPS)
        self.displayFPS = MirageRenderModePolicy.normalizedTargetFPS(displayFPS)
        self.transportPathKind = transportPathKind
        self.mediaPathProfile = resolvedMediaPathProfile
        self.hasRecentInteraction = hasRecentInteraction
        self.lastInteractionAgeSeconds = lastInteractionAgeSeconds
        self.awdlReceiverPlayoutDelayTargetMs = awdlReceiverPlayoutDelayTargetMs.map {
            min(
                MirageAwdlMediaController.maximumPlayoutDelayMs,
                max(MirageAwdlMediaController.minimumPlayoutDelayMs, $0)
            )
        }
    }

    package var targetPlayoutDelayFrames: Int {
        if usesAwdlRealtimePolicy {
            return max(1, Int((baseTargetPlayoutDelayMs / sourceFrameIntervalMs).rounded(.up)))
        }
        switch latencyMode {
        case .lowestLatency:
            return 0
        case .balanced:
            return MirageMedia.MirageStreamCadenceTarget.defaultPlayoutDelayFrames(for: .balanced)
        case .smoothest:
            return MirageMedia.MirageStreamCadenceTarget.defaultPlayoutDelayFrames(for: .smoothest)
        }
    }

    package var maximumQueueDepth: Int {
        if usesAwdlRealtimePolicy {
            return min(
                32,
                max(8, Int(((maximumTargetPlayoutDelayMs + 100) / displayFrameIntervalMs).rounded(.up)))
            )
        }
        switch latencyMode {
        case .lowestLatency:
            return 1
        case .balanced:
            return 4
        case .smoothest:
            return min(
                32,
                max(3, Int(((maximumTargetPlayoutDelayMs + 150) / displayFrameIntervalMs).rounded(.up)) + 1)
            )
        }
    }

    package var maximumQueueAgeMs: Double {
        if usesAwdlRealtimePolicy {
            return min(
                MirageAwdlMediaController.maximumReceiverQueueAgeMs,
                max(160, maximumTargetPlayoutDelayMs + displayFrameIntervalMs * 5)
            )
        }
        switch latencyMode {
        case .lowestLatency:
            return sourceFrameIntervalMs
        case .balanced:
            return max(120, displayFrameIntervalMs * 6)
        case .smoothest:
            return max(300, maximumTargetPlayoutDelayMs + 250)
        }
    }

    package var smoothestDisplayDebtCapMs: Double {
        guard usesBufferedPlayout else {
            return sourceFrameIntervalMs
        }
        if usesAwdlRealtimePolicy {
            return min(
                MirageAwdlMediaController.maximumReceiverDisplayDebtMs,
                max(
                    100,
                    effectiveTargetPlayoutDelayMs(adaptedDelayMs: baseTargetPlayoutDelayMs) +
                        displayFrameIntervalMs * 3
                )
            )
        }
        if latencyMode == .balanced {
            return max(
                50,
                effectiveTargetPlayoutDelayMs(adaptedDelayMs: baseTargetPlayoutDelayMs) +
                    displayFrameIntervalMs * 2
            )
        }
        return max(100, effectiveTargetPlayoutDelayMs(adaptedDelayMs: baseTargetPlayoutDelayMs) + 50)
    }

    package var hardResetDebtMs: Double {
        if usesAwdlRealtimePolicy {
            return min(
                MirageAwdlMediaController.maximumReceiverHardResetDebtMs,
                max(
                    MirageAwdlMediaController.maximumReceiverDisplayDebtMs,
                    maximumTargetPlayoutDelayMs + displayFrameIntervalMs * 5
                )
            )
        }
        switch latencyMode {
        case .lowestLatency:
            return sourceFrameIntervalMs
        case .balanced:
            return max(80, displayFrameIntervalMs * 4)
        case .smoothest:
            return max(300, baseTargetPlayoutDelayMs + 250)
        }
    }

    package var displayFrameIntervalMs: Double {
        1000 / Double(max(1, displayFPS))
    }

    package var sourceFrameIntervalMs: Double {
        1000 / Double(max(1, sourceFPS))
    }

    package var baseTargetPlayoutDelayMs: Double {
        if usesAwdlRealtimePolicy {
            return awdlReceiverPlayoutDelayTargetMs ?? MirageAwdlMediaController.basePlayoutDelayMs
        }
        switch latencyMode {
        case .lowestLatency:
            return 0
        case .balanced:
            return displayFrameIntervalMs * 2
        case .smoothest:
            switch transportPathKind {
            case .wired, .loopback:
                return 50
            case .wifi:
                return 100
            case .awdl:
                return 160
            case .vpn, .cellular, .other, .unknown:
                return 250
            }
        }
    }

    package var minimumTargetPlayoutDelayMs: Double {
        if usesAwdlRealtimePolicy {
            return MirageAwdlMediaController.minimumPlayoutDelayMs
        }
        switch latencyMode {
        case .lowestLatency:
            return 0
        case .balanced:
            return displayFrameIntervalMs
        case .smoothest:
            switch transportPathKind {
            case .awdl:
                return 60
            case .wired, .loopback:
                return 30
            case .wifi:
                return 60
            case .vpn, .cellular, .other, .unknown:
                return 100
            }
        }
    }

    package var maximumTargetPlayoutDelayMs: Double {
        if usesAwdlRealtimePolicy {
            return MirageAwdlMediaController.maximumPlayoutDelayMs
        }
        switch latencyMode {
        case .lowestLatency:
            return 0
        case .balanced:
            return displayFrameIntervalMs * 3
        case .smoothest:
            return max(350, baseTargetPlayoutDelayMs * 2)
        }
    }

    package var maximumRetainedPixelBufferBytes: Int {
        if usesAwdlRealtimePolicy {
            return 384 * 1024 * 1024
        }
        switch latencyMode {
        case .lowestLatency:
            return 96 * 1024 * 1024
        case .balanced:
            return 192 * 1024 * 1024
        case .smoothest:
            return 384 * 1024 * 1024
        }
    }

    package var inputDelayReductionFraction: Double {
        guard usesBufferedPlayout, hasRecentInteraction else { return 0 }
        guard !usesAwdlRealtimePolicy else { return 0 }
        let maximumReduction = 0.40
        guard let age = lastInteractionAgeSeconds else { return maximumReduction }

        let rampDuration: CFTimeInterval = 0.250
        let holdDuration: CFTimeInterval = 0.500
        let releaseDuration: CFTimeInterval = 0.750
        if age <= 0 {
            return 0
        }
        if age < rampDuration {
            return maximumReduction * (age / rampDuration)
        }
        if age < rampDuration + holdDuration {
            return maximumReduction
        }
        let releaseAge = age - rampDuration - holdDuration
        guard releaseAge < releaseDuration else { return 0 }
        return maximumReduction * (1 - releaseAge / releaseDuration)
    }

    package func effectiveTargetPlayoutDelayMs(adaptedDelayMs: Double) -> Double {
        guard usesBufferedPlayout else { return 0 }
        let clamped = min(max(adaptedDelayMs, minimumTargetPlayoutDelayMs), maximumTargetPlayoutDelayMs)
        let reduced = clamped * (1 - inputDelayReductionFraction)
        return max(minimumTargetPlayoutDelayMs, reduced)
    }

    package var usesBufferedPlayout: Bool {
        usesAwdlRealtimePolicy || latencyMode == .balanced || latencyMode == .smoothest
    }

    package var usesAwdlRealtimePolicy: Bool {
        mediaPathProfile.usesAwdlRadioPolicy
    }

}
