//
//  MirageAwdlMediaController.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/25/26.
//
//  Central policy owner for AWDL realtime display behavior.
//

import Foundation

package struct MirageAwdlMediaController: Sendable, Equatable {
    package enum State: String, Codable, Sendable, Equatable {
        case warmup
        case steady
        case stressed
        case recovery
        case demote
    }

    package enum Trigger: String, Codable, Sendable, Equatable {
        case warmup
        case stable
        case jitter
        case loss
        case reassemblyBacklog
        case pFrameLatency
        case decodePressure
        case presentationUnderflow
        case recovery
        case demote
        case nonAwdl
    }

    package struct Signal: Sendable, Equatable {
        package var mediaPathProfile: MirageMediaPathProfile
        package var currentFrameRate: Int
        package var targetFrameRate: Int
        package var targetBitrateBps: Int?
        package var jitterP99Ms: Double
        package var receivedWorstGapMs: Double?
        package var pFrameCompletionLatencyP95Ms: Double?
        package var latePFrameCount: UInt64
        package var missingFragmentTimeouts: UInt64
        package var forwardGapTimeouts: UInt64
        package var lostFrameCount: UInt64
        package var discardedPacketCount: UInt64
        package var reassemblyBacklogFrames: Int
        package var reassemblyBacklogBytes: Int
        package var decodeBacklogFrames: Int
        package var presentationBacklogFrames: Int
        package var presentationStallCount: UInt64
        package var displayTickNoFrameCount: UInt64
        package var fecRecoveredFragmentCount: UInt64
        package var recoveryState: MirageMediaFeedbackRecoveryState

        package init(
            mediaPathProfile: MirageMediaPathProfile,
            currentFrameRate: Int,
            targetFrameRate: Int,
            targetBitrateBps: Int? = nil,
            jitterP99Ms: Double = 0,
            receivedWorstGapMs: Double? = nil,
            pFrameCompletionLatencyP95Ms: Double? = nil,
            latePFrameCount: UInt64 = 0,
            missingFragmentTimeouts: UInt64 = 0,
            forwardGapTimeouts: UInt64 = 0,
            lostFrameCount: UInt64 = 0,
            discardedPacketCount: UInt64 = 0,
            reassemblyBacklogFrames: Int = 0,
            reassemblyBacklogBytes: Int = 0,
            decodeBacklogFrames: Int = 0,
            presentationBacklogFrames: Int = 0,
            presentationStallCount: UInt64 = 0,
            displayTickNoFrameCount: UInt64 = 0,
            fecRecoveredFragmentCount: UInt64 = 0,
            recoveryState: MirageMediaFeedbackRecoveryState = .idle
        ) {
            self.mediaPathProfile = mediaPathProfile
            self.currentFrameRate = max(1, currentFrameRate)
            self.targetFrameRate = max(1, targetFrameRate)
            self.targetBitrateBps = targetBitrateBps.map { max(1, $0) }
            self.jitterP99Ms = max(0, jitterP99Ms)
            self.receivedWorstGapMs = receivedWorstGapMs.map { max(0, $0) }
            self.pFrameCompletionLatencyP95Ms = pFrameCompletionLatencyP95Ms.map { max(0, $0) }
            self.latePFrameCount = latePFrameCount
            self.missingFragmentTimeouts = missingFragmentTimeouts
            self.forwardGapTimeouts = forwardGapTimeouts
            self.lostFrameCount = lostFrameCount
            self.discardedPacketCount = discardedPacketCount
            self.reassemblyBacklogFrames = max(0, reassemblyBacklogFrames)
            self.reassemblyBacklogBytes = max(0, reassemblyBacklogBytes)
            self.decodeBacklogFrames = max(0, decodeBacklogFrames)
            self.presentationBacklogFrames = max(0, presentationBacklogFrames)
            self.presentationStallCount = presentationStallCount
            self.displayTickNoFrameCount = displayTickNoFrameCount
            self.fecRecoveredFragmentCount = fecRecoveredFragmentCount
            self.recoveryState = recoveryState
        }

        package init(
            feedback: ReceiverMediaFeedbackMessage,
            currentFrameRate: Int,
            mediaPathProfile: MirageMediaPathProfile,
            targetBitrateBps: Int? = nil
        ) {
            self.init(
                mediaPathProfile: mediaPathProfile,
                currentFrameRate: currentFrameRate,
                targetFrameRate: feedback.targetFPS,
                targetBitrateBps: targetBitrateBps,
                jitterP99Ms: feedback.receiverJitterP99Ms ?? feedback.jitterP99Ms,
                receivedWorstGapMs: feedback.receivedWorstGapMs,
                pFrameCompletionLatencyP95Ms: feedback.pFrameCompletionLatencyP95Ms,
                latePFrameCount: feedback.latePFrameCount ?? 0,
                missingFragmentTimeouts: feedback.reassemblerMissingFragmentTimeouts ?? 0,
                forwardGapTimeouts: feedback.reassemblerForwardGapTimeouts ?? 0,
                lostFrameCount: feedback.lostFrameCount,
                discardedPacketCount: feedback.discardedPacketCount,
                reassemblyBacklogFrames: feedback.reassemblyBacklogFrames,
                reassemblyBacklogBytes: feedback.reassemblyBacklogBytes,
                decodeBacklogFrames: feedback.decodeBacklogFrames,
                presentationBacklogFrames: feedback.presentationBacklogFrames,
                presentationStallCount: feedback.presentationStallCount ?? 0,
                displayTickNoFrameCount: feedback.displayTickNoFrameCount ?? 0,
                fecRecoveredFragmentCount: feedback.fecRecoveredFragmentCount ?? 0,
                recoveryState: feedback.recoveryState
            )
        }
    }

    package struct Decision: Sendable, Equatable {
        package var state: State
        package var trigger: Trigger
        package var targetFrameRate: Int
        package var resolutionScale: Double
        package var hostPacingBudgetBps: Int
        package var keyframePacingBudgetBps: Int
        package var pFramePacketBurst: Int
        package var keyframePacketBurst: Int
        package var pFrameFECBlockSize: Int
        package var keyframeFECBlockSize: Int
        package var continuityWindowMs: Double
        package var playoutDelayMs: Double
        package var pacingHoldSeconds: Double
        package var qualityReductionAllowed: Bool

        package var usesFixedRealtimeDisplayPolicy: Bool {
            state != .steady || trigger != .nonAwdl
        }
    }

    package static let defaultPacingBudgetBps = 32_000_000
    package static let pFramePacketBurst = 2
    package static let keyframePacketBurst = 4
    package static let startupKeyframeFECBlockSize = 4
    package static let baseContinuityWindowMs = 180.0
    package static let maximumContinuityWindowMs = 300.0
    package static let basePlayoutDelayMs = 24.0
    package static let minimumPlayoutDelayMs = 24.0
    package static let stableMaximumPlayoutDelayMs = 80.0
    package static let maximumPlayoutDelayMs = 120.0
    package static let decodeQueueWindowMs = 600.0
    package static let pacingHoldSeconds = 2.0

    private static let stressSamplesRequired = 2
    private static let stableSamplesForSteady = 3
    private static let demoteSamplesRequired = 4

    package private(set) var state: State
    private var consecutiveStressSamples: Int
    private var consecutiveStableSamples: Int
    private var consecutiveDemoteSamples: Int
    private var currentPlayoutDelayMs: Double
    private var currentResolutionScale: Double

    package init(state: State = .warmup) {
        self.state = state
        consecutiveStressSamples = 0
        consecutiveStableSamples = 0
        consecutiveDemoteSamples = 0
        currentPlayoutDelayMs = Self.basePlayoutDelayMs
        currentResolutionScale = 1.0
    }

    package static func fixedLatencyMode(
        requestedLatencyMode: MirageStreamLatencyMode,
        mediaPathProfile: MirageMediaPathProfile
    ) -> MirageStreamLatencyMode {
        mediaPathProfile.usesAwdlRadioPolicy ? .balanced : requestedLatencyMode
    }

    package static func fixedDisplayTargetFrameRate(
        requestedFrameRate: Int,
        mediaPathProfile: MirageMediaPathProfile
    ) -> Int {
        guard mediaPathProfile.usesAwdlRadioPolicy else { return max(1, requestedFrameRate) }
        return min(max(1, requestedFrameRate), 60)
    }

    package static func continuityWindowMs(
        pFrameCompletionLatencyP95Ms: Double,
        latePFrameCount: UInt64
    ) -> Double {
        let measured = pFrameCompletionLatencyP95Ms > 0
            ? pFrameCompletionLatencyP95Ms * 1.25
            : baseContinuityWindowMs
        let lateCompletionBonus = latePFrameCount > 0 ? 40.0 : 0
        return min(maximumContinuityWindowMs, max(baseContinuityWindowMs, measured + lateCompletionBonus))
    }

    package static func playoutDelayMs(
        jitterP99Ms: Double = 0,
        receivedWorstGapMs: Double? = nil,
        presentationStallCount: UInt64 = 0,
        hasRecentInteraction: Bool = false
    ) -> Double {
        let gapPressureMs = max(jitterP99Ms, receivedWorstGapMs ?? 0)
        let pressureDelay: Double
        if presentationStallCount > 0 || gapPressureMs >= 240 {
            pressureDelay = 120
        } else if gapPressureMs >= 180 {
            pressureDelay = 96
        } else if gapPressureMs >= 120 {
            pressureDelay = 80
        } else if gapPressureMs >= 80 {
            pressureDelay = 64
        } else if gapPressureMs >= 50 {
            pressureDelay = 48
        } else {
            pressureDelay = basePlayoutDelayMs
        }
        let reducedDelay = hasRecentInteraction ? pressureDelay * 0.80 : pressureDelay
        return min(maximumPlayoutDelayMs, max(minimumPlayoutDelayMs, reducedDelay))
    }

    package static func videoToolboxDataRateWindowSeconds(targetFrameRate: Int) -> Double {
        max(1, targetFrameRate) >= 90 ? 0.10 : 0.15
    }

    package static func pacingBudgetBps(targetBitrateBps: Int?) -> Int {
        min(max(1, targetBitrateBps ?? defaultPacingBudgetBps), defaultPacingBudgetBps)
    }

    package static func pFrameFECBlockSize(
        frameByteCount: Int,
        maxPayloadSize: Int,
        isLossModeActive: Bool
    ) -> Int {
        if isLossModeActive { return 4 }
        return 0
    }

    package static func keyframeFECBlockSize() -> Int {
        4
    }

    package static func startupKeyframeFECBlockSizeForAwdlRadio() -> Int {
        startupKeyframeFECBlockSize
    }

    package mutating func update(with signal: Signal) -> Decision {
        guard signal.mediaPathProfile.usesAwdlRadioPolicy else {
            state = .steady
            consecutiveStressSamples = 0
            consecutiveStableSamples += 1
            consecutiveDemoteSamples = 0
            currentPlayoutDelayMs = Self.basePlayoutDelayMs
            currentResolutionScale = 1.0
            return Self.decision(
                state: state,
                trigger: .nonAwdl,
                signal: signal,
                playoutDelayMs: currentPlayoutDelayMs,
                resolutionScale: currentResolutionScale,
                qualityReductionAllowed: false
            )
        }

        let trigger = Self.trigger(for: signal)
        switch trigger {
        case .stable:
            consecutiveStableSamples += 1
            consecutiveStressSamples = 0
            consecutiveDemoteSamples = 0
            if consecutiveStableSamples >= Self.stableSamplesForSteady {
                state = .steady
                currentResolutionScale = 1.0
            } else if state == .recovery || state == .demote {
                state = .stressed
            }
        case .recovery:
            consecutiveStableSamples = 0
            consecutiveStressSamples = 0
            consecutiveDemoteSamples = 0
            state = .recovery
        case .demote:
            consecutiveStableSamples = 0
            consecutiveStressSamples += 1
            consecutiveDemoteSamples += 1
            state = consecutiveDemoteSamples >= Self.demoteSamplesRequired ? .demote : .stressed
            if state == .demote {
                currentResolutionScale = consecutiveDemoteSamples >= Self.demoteSamplesRequired * 2 ? 0.75 : 0.875
            }
        case .jitter,
             .loss,
             .reassemblyBacklog,
             .pFrameLatency,
             .decodePressure,
             .presentationUnderflow:
            consecutiveStableSamples = 0
            consecutiveStressSamples += 1
            if trigger.demotesCadence {
                consecutiveDemoteSamples += 1
            } else {
                consecutiveDemoteSamples = 0
            }
            if consecutiveStressSamples >= Self.stressSamplesRequired || state == .recovery {
                state = .stressed
            }
            if consecutiveDemoteSamples >= Self.demoteSamplesRequired {
                state = .demote
                currentResolutionScale = consecutiveDemoteSamples >= Self.demoteSamplesRequired * 2 ? 0.75 : 0.875
            }
        case .warmup:
            consecutiveStableSamples = 0
            consecutiveStressSamples = 0
            consecutiveDemoteSamples = 0
            state = .warmup
        case .nonAwdl:
            state = .steady
        }

        return Self.decision(
            state: state,
            trigger: trigger,
            signal: signal,
            playoutDelayMs: updatePlayoutDelay(trigger: trigger, signal: signal),
            resolutionScale: currentResolutionScale,
            qualityReductionAllowed: state == .demote
        )
    }

    private mutating func updatePlayoutDelay(
        trigger: Trigger,
        signal: Signal
    ) -> Double {
        guard signal.mediaPathProfile.usesAwdlRadioPolicy else {
            currentPlayoutDelayMs = Self.basePlayoutDelayMs
            return currentPlayoutDelayMs
        }

        let measuredDelayMs = Self.playoutDelayMs(
            jitterP99Ms: signal.jitterP99Ms,
            receivedWorstGapMs: signal.receivedWorstGapMs,
            presentationStallCount: signal.presentationStallCount
        )
        switch trigger {
        case .stable, .warmup:
            if currentPlayoutDelayMs <= Self.basePlayoutDelayMs {
                currentPlayoutDelayMs = Self.basePlayoutDelayMs
            } else if consecutiveStableSamples >= Self.stableSamplesForSteady {
                let frameIntervalMs = 1_000.0 / Double(max(1, signal.currentFrameRate))
                currentPlayoutDelayMs = max(
                    Self.basePlayoutDelayMs,
                    currentPlayoutDelayMs - max(8.0, frameIntervalMs)
                )
            }
        case .nonAwdl:
            currentPlayoutDelayMs = Self.basePlayoutDelayMs
        case .jitter,
             .loss,
             .reassemblyBacklog,
             .pFrameLatency,
             .decodePressure,
             .presentationUnderflow,
             .recovery,
             .demote:
            currentPlayoutDelayMs = min(
                Self.maximumPlayoutDelayMs,
                max(currentPlayoutDelayMs, measuredDelayMs)
            )
        }

        let maximumDelay = trigger == .stable ? Self.stableMaximumPlayoutDelayMs : Self.maximumPlayoutDelayMs
        return min(maximumDelay, max(Self.minimumPlayoutDelayMs, currentPlayoutDelayMs))
    }

    private static func decision(
        state: State,
        trigger: Trigger,
        signal: Signal,
        playoutDelayMs: Double,
        resolutionScale: Double,
        qualityReductionAllowed: Bool
    ) -> Decision {
        Decision(
            state: state,
            trigger: trigger,
            targetFrameRate: interactiveDisplayTargetFrameRate(
                state: state,
                trigger: trigger,
                currentFrameRate: signal.currentFrameRate,
                requestedFrameRate: max(signal.currentFrameRate, signal.targetFrameRate),
                mediaPathProfile: signal.mediaPathProfile
            ),
            resolutionScale: min(1.0, max(0.75, resolutionScale)),
            hostPacingBudgetBps: pacingBudgetBps(targetBitrateBps: signal.targetBitrateBps),
            keyframePacingBudgetBps: pacingBudgetBps(targetBitrateBps: signal.targetBitrateBps),
            pFramePacketBurst: pFramePacketBurst,
            keyframePacketBurst: keyframePacketBurst,
            pFrameFECBlockSize: pFrameFECBlockSize(
                frameByteCount: signal.reassemblyBacklogBytes,
                maxPayloadSize: 1_200,
                isLossModeActive: trigger == .loss || state == .recovery
            ),
            keyframeFECBlockSize: keyframeFECBlockSize(),
            continuityWindowMs: continuityWindowMs(
                pFrameCompletionLatencyP95Ms: signal.pFrameCompletionLatencyP95Ms ?? 0,
                latePFrameCount: signal.latePFrameCount
            ),
            playoutDelayMs: playoutDelayMs,
            pacingHoldSeconds: pacingHoldSeconds,
            qualityReductionAllowed: qualityReductionAllowed
        )
    }

    private static func interactiveDisplayTargetFrameRate(
        state: State,
        trigger: Trigger,
        currentFrameRate: Int,
        requestedFrameRate: Int,
        mediaPathProfile: MirageMediaPathProfile
    ) -> Int {
        guard mediaPathProfile.usesAwdlRadioPolicy else { return max(1, requestedFrameRate) }
        let ceiling = min(max(1, requestedFrameRate), 60)
        switch state {
        case .demote:
            return min(30, ceiling)
        case .recovery:
            return min(45, ceiling)
        case .stressed:
            switch trigger {
            case .decodePressure, .presentationUnderflow, .pFrameLatency, .reassemblyBacklog:
                return min(max(30, currentFrameRate > 45 ? 45 : 30), ceiling)
            case .loss, .jitter:
                return min(max(45, currentFrameRate), ceiling)
            case .warmup, .stable, .recovery, .demote, .nonAwdl:
                return ceiling
            }
        case .warmup, .steady:
            return ceiling
        }
    }

    private static func trigger(for signal: Signal) -> Trigger {
        guard signal.mediaPathProfile.usesAwdlRadioPolicy else { return .nonAwdl }
        if signal.recoveryState != .idle || signal.forwardGapTimeouts > 0 {
            return .recovery
        }

        let currentFrameRate = max(signal.currentFrameRate, signal.targetFrameRate)
        let frameIntervalMs = 1_000.0 / Double(max(1, currentFrameRate))
        let jitterStress = signal.jitterP99Ms >= max(60.0, frameIntervalMs * 4.0)
        let receivedGapStress = (signal.receivedWorstGapMs ?? 0) >= max(100.0, frameIntervalMs * 6.0)
        let unrepairedMissingFragments = signal.missingFragmentTimeouts > signal.fecRecoveredFragmentCount
        let lossStress = signal.lostFrameCount >= 6 ||
            signal.discardedPacketCount >= 6 ||
            unrepairedMissingFragments
        let reassemblyBacklogStress = signal.reassemblyBacklogFrames >= 8 ||
            signal.reassemblyBacklogBytes >= 2_000_000
        let pFrameLatencyStress = (signal.pFrameCompletionLatencyP95Ms ?? 0) >= max(50.0, frameIntervalMs * 3.0) ||
            signal.latePFrameCount >= 4
        let decodePressure = signal.decodeBacklogFrames >= 4 ||
            signal.presentationBacklogFrames >= 4
        let presentationUnderflow = signal.presentationStallCount > 0 ||
            signal.displayTickNoFrameCount >= UInt64(max(3, currentFrameRate / 20))

        if lossStress { return .loss }
        if reassemblyBacklogStress { return .reassemblyBacklog }
        if pFrameLatencyStress { return .pFrameLatency }
        if decodePressure { return .decodePressure }
        if presentationUnderflow { return .presentationUnderflow }
        if jitterStress || receivedGapStress { return .jitter }
        return .stable
    }
}

private extension MirageAwdlMediaController.Trigger {
    var demotesCadence: Bool {
        switch self {
        case .reassemblyBacklog,
             .pFrameLatency,
             .decodePressure,
             .presentationUnderflow,
             .demote:
            true
        case .warmup,
             .stable,
             .jitter,
             .loss,
             .recovery,
             .nonAwdl:
            false
        }
    }
}
