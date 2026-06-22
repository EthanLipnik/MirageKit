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
        case starting
        case awaitingFirstFrame
        case steady
        case stressed
        case recovering
        case demoted
        case failed
    }

    package enum Trigger: String, Codable, Sendable, Equatable {
        case startup
        case stable
        case jitter
        case loss
        case reassemblyBacklog
        case pFrameLatency
        case decodePressure
        case presentationBacklog
        case presentationFillDeficit
        case presentationUnderflow
        case recovery
        case demote
        case nonAwdl
    }

    package enum SelectedLever: String, Codable, Sendable, Equatable {
        case observe
        case playout
        case pacing
        case resolution
        case quality
        case recovery
    }

    package struct Signal: Sendable, Equatable {
        package var mediaPathProfile: MirageMediaPathProfile
        package var currentFrameRate: Int
        package var targetFrameRate: Int
        package var requestedFrameRateCeiling: Int?
        package var targetBitrateBps: Int?
        package var jitterP99Ms: Double
        package var frameCompletionLatencyP95Ms: Double?
        package var keyframeCompletionLatencyP95Ms: Double?
        package var pFrameCompletionLatencyP95Ms: Double?
        package var receiverPlayoutDelayTargetMs: Double?
        package var latePFrameCount: UInt64
        package var missingFragmentTimeouts: UInt64
        package var forwardGapTimeouts: UInt64
        package var lostFrameCount: UInt64
        package var discardedPacketCount: UInt64
        package var reassemblyBacklogFrames: Int
        package var reassemblyBacklogBytes: Int
        package var decodeBacklogFrames: Int
        package var decodeSubmissionLimit: Int?
        package var inFlightDecodeSubmissions: Int?
        package var decodedFPS: Double
        package var receivedFPS: Double
        package var presentationBacklogFrames: Int
        package var presentationFillDeficitFrames: Int
        package var presentationUnderfillFrames: Int
        package var presentationStallCount: UInt64
        package var displayTickNoFrameCount: UInt64
        package var pendingFrameNotReadyDisplayTickCount: UInt64
        package var fecRecoveredFragmentCount: UInt64
        package var recoveryState: MirageMediaFeedbackRecoveryState

        package init(
            mediaPathProfile: MirageMediaPathProfile,
            currentFrameRate: Int,
            targetFrameRate: Int,
            requestedFrameRateCeiling: Int? = nil,
            targetBitrateBps: Int? = nil,
            jitterP99Ms: Double = 0,
            frameCompletionLatencyP95Ms: Double? = nil,
            keyframeCompletionLatencyP95Ms: Double? = nil,
            pFrameCompletionLatencyP95Ms: Double? = nil,
            receiverPlayoutDelayTargetMs: Double? = nil,
            latePFrameCount: UInt64 = 0,
            missingFragmentTimeouts: UInt64 = 0,
            forwardGapTimeouts: UInt64 = 0,
            lostFrameCount: UInt64 = 0,
            discardedPacketCount: UInt64 = 0,
            reassemblyBacklogFrames: Int = 0,
            reassemblyBacklogBytes: Int = 0,
            decodeBacklogFrames: Int = 0,
            decodeSubmissionLimit: Int? = nil,
            inFlightDecodeSubmissions: Int? = nil,
            decodedFPS: Double = 0,
            receivedFPS: Double = 0,
            presentationBacklogFrames: Int = 0,
            presentationFillDeficitFrames: Int = 0,
            presentationUnderfillFrames: Int = 0,
            presentationStallCount: UInt64 = 0,
            displayTickNoFrameCount: UInt64 = 0,
            pendingFrameNotReadyDisplayTickCount: UInt64 = 0,
            fecRecoveredFragmentCount: UInt64 = 0,
            recoveryState: MirageMediaFeedbackRecoveryState = .idle
        ) {
            self.mediaPathProfile = mediaPathProfile
            self.currentFrameRate = max(1, currentFrameRate)
            self.targetFrameRate = max(1, targetFrameRate)
            self.requestedFrameRateCeiling = requestedFrameRateCeiling.map { max(1, $0) }
            self.targetBitrateBps = targetBitrateBps.map { max(1, $0) }
            self.jitterP99Ms = max(0, jitterP99Ms)
            self.frameCompletionLatencyP95Ms = frameCompletionLatencyP95Ms.map { max(0, $0) }
            self.keyframeCompletionLatencyP95Ms = keyframeCompletionLatencyP95Ms.map { max(0, $0) }
            self.pFrameCompletionLatencyP95Ms = pFrameCompletionLatencyP95Ms.map { max(0, $0) }
            self.receiverPlayoutDelayTargetMs = receiverPlayoutDelayTargetMs.map { max(0, $0) }
            self.latePFrameCount = latePFrameCount
            self.missingFragmentTimeouts = missingFragmentTimeouts
            self.forwardGapTimeouts = forwardGapTimeouts
            self.lostFrameCount = lostFrameCount
            self.discardedPacketCount = discardedPacketCount
            self.reassemblyBacklogFrames = max(0, reassemblyBacklogFrames)
            self.reassemblyBacklogBytes = max(0, reassemblyBacklogBytes)
            self.decodeBacklogFrames = max(0, decodeBacklogFrames)
            self.decodeSubmissionLimit = decodeSubmissionLimit.map { max(0, $0) }
            self.inFlightDecodeSubmissions = inFlightDecodeSubmissions.map { max(0, $0) }
            self.decodedFPS = max(0, decodedFPS)
            self.receivedFPS = max(0, receivedFPS)
            self.presentationBacklogFrames = max(0, presentationBacklogFrames)
            self.presentationFillDeficitFrames = max(0, presentationFillDeficitFrames)
            self.presentationUnderfillFrames = max(0, presentationUnderfillFrames)
            self.presentationStallCount = presentationStallCount
            self.displayTickNoFrameCount = displayTickNoFrameCount
            self.pendingFrameNotReadyDisplayTickCount = pendingFrameNotReadyDisplayTickCount
            self.fecRecoveredFragmentCount = fecRecoveredFragmentCount
            self.recoveryState = recoveryState
        }

        package init(
            feedback: ReceiverMediaFeedbackMessage,
            currentFrameRate: Int,
            mediaPathProfile: MirageMediaPathProfile,
            requestedFrameRateCeiling: Int? = nil,
            targetBitrateBps: Int? = nil
        ) {
            let presentationQueueBacklog = feedback.presentationQueueDepth.map { queueDepth in
                guard let targetFrames = feedback.presentationTargetFrames else { return 0 }
                return max(0, queueDepth - targetFrames)
            } ?? 0
            self.init(
                mediaPathProfile: mediaPathProfile,
                currentFrameRate: currentFrameRate,
                targetFrameRate: feedback.targetFPS,
                requestedFrameRateCeiling: requestedFrameRateCeiling,
                targetBitrateBps: targetBitrateBps,
                jitterP99Ms: feedback.receiverJitterP99Ms ?? 0,
                frameCompletionLatencyP95Ms: feedback.frameCompletionLatencyP95Ms,
                keyframeCompletionLatencyP95Ms: feedback.keyframeCompletionLatencyP95Ms,
                pFrameCompletionLatencyP95Ms: feedback.pFrameCompletionLatencyP95Ms,
                receiverPlayoutDelayTargetMs: feedback.playoutDelayTargetMs,
                latePFrameCount: feedback.latePFrameCount ?? 0,
                missingFragmentTimeouts: feedback.reassemblerMissingFragmentTimeouts ?? 0,
                forwardGapTimeouts: feedback.reassemblerForwardGapTimeouts ?? 0,
                lostFrameCount: feedback.lostFrameCount,
                discardedPacketCount: feedback.discardedPacketCount,
                reassemblyBacklogFrames: feedback.reassemblyBacklogFrames,
                reassemblyBacklogBytes: feedback.reassemblyBacklogBytes,
                decodeBacklogFrames: max(feedback.decodeBacklogFrames, feedback.decodeQueueDepth ?? 0),
                decodeSubmissionLimit: feedback.decodeSubmissionLimit,
                inFlightDecodeSubmissions: feedback.inFlightDecodeSubmissions,
                decodedFPS: feedback.decodedFPS,
                receivedFPS: feedback.receivedFPS,
                presentationBacklogFrames: max(
                    feedback.presentationBacklogFrames,
                    presentationQueueBacklog
                ),
                presentationFillDeficitFrames: feedback.presentationFillDeficitFrames ?? 0,
                presentationUnderfillFrames: feedback.presentationUnderfillFrames ?? 0,
                presentationStallCount: feedback.presentationStallCount ?? 0,
                displayTickNoFrameCount: feedback.displayTickNoFrameCount ?? 0,
                pendingFrameNotReadyDisplayTickCount: feedback.pendingFrameNotReadyDisplayTickCount ?? 0,
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
        package var selectedLever: SelectedLever

        package var usesFixedRealtimeDisplayPolicy: Bool {
            state != .steady || trigger != .nonAwdl
        }
    }

    package static let defaultPacingBudgetBps = 32_000_000
    package static let defaultKeyframePacingBudgetBps = 48_000_000
    package static let pFramePacketBurst = 2
    package static let keyframePacketBurst = 4
    package static let startupKeyframeFECBlockSize = 4
    package static let baseContinuityWindowMs = 140.0
    package static let maximumContinuityWindowMs = 220.0
    package static let basePlayoutDelayMs = 33.0
    package static let minimumPlayoutDelayMs = 24.0
    package static let stableMaximumPlayoutDelayMs = 80.0
    package static let maximumPlayoutDelayMs = 120.0
    package static let maximumReceiverQueueAgeMs = 220.0
    package static let maximumReceiverDisplayDebtMs = 160.0
    package static let maximumReceiverHardResetDebtMs = 240.0
    package static let decodeQueueWindowMs = 250.0
    package static let pacingHoldSeconds = 2.0
    package static let awdlRadioFrameRate = 20

    private static let stressSamplesRequired = 2
    private static let stableSamplesForSteady = 3
    private static let demoteSamplesRequired = 4
    private static let survivalSamplesRequired = 8

    package private(set) var state: State
    private var consecutiveStressSamples: Int
    private var consecutiveStableSamples: Int
    private var consecutiveDemoteSamples: Int
    private var currentPlayoutDelayMs: Double
    private var currentResolutionScale: Double

    package init(state: State = .starting) {
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
        return awdlRadioFrameRate
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
        presentationStallCount: UInt64 = 0,
        recoveryState: MirageMediaFeedbackRecoveryState = .idle,
        hasRecentInteraction: Bool = false
    ) -> Double {
        let gapPressureMs = jitterP99Ms
        let pressureDelay: Double
        if presentationStallCount > 0 || recoveryState != .idle {
            pressureDelay = maximumPlayoutDelayMs
        } else if gapPressureMs >= 180 {
            pressureDelay = stableMaximumPlayoutDelayMs
        } else if gapPressureMs >= 120 {
            pressureDelay = stableMaximumPlayoutDelayMs
        } else if gapPressureMs >= 80 {
            pressureDelay = 64
        } else if gapPressureMs >= 50 {
            pressureDelay = 48
        } else {
            pressureDelay = basePlayoutDelayMs
        }
        let reducedDelay = hasRecentInteraction ? pressureDelay * 0.85 : pressureDelay
        return min(maximumPlayoutDelayMs, max(minimumPlayoutDelayMs, reducedDelay))
    }

    package static func videoToolboxDataRateWindowSeconds(targetFrameRate: Int) -> Double {
        max(1, targetFrameRate) >= 90 ? 0.10 : 0.15
    }

    package static func pacingBudgetBps(targetBitrateBps: Int?) -> Int {
        min(max(1, targetBitrateBps ?? defaultPacingBudgetBps), defaultPacingBudgetBps)
    }

    package static func keyframePacingBudgetBps(
        targetBitrateBps: Int?,
        state: State
    ) -> Int {
        let pFrameBudget = pacingBudgetBps(targetBitrateBps: targetBitrateBps)
        let keyframeBudget = min(
            defaultKeyframePacingBudgetBps,
            max(defaultPacingBudgetBps, targetBitrateBps ?? defaultKeyframePacingBudgetBps)
        )
        switch state {
        case .failed:
            return pFrameBudget
        case .starting,
             .awaitingFirstFrame,
             .steady,
             .stressed,
             .recovering,
             .demoted:
            return keyframeBudget
        }
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
            } else if state == .recovering || state == .failed {
                state = .stressed
            }
        case .recovery:
            consecutiveStableSamples = 0
            consecutiveStressSamples = 0
            consecutiveDemoteSamples = 0
            state = signal.recoveryState == .hardRecovery ? .failed : .recovering
        case .demote:
            consecutiveStableSamples = 0
            consecutiveStressSamples += 1
            consecutiveDemoteSamples += 1
            if consecutiveDemoteSamples >= Self.survivalSamplesRequired {
                state = .demoted
                currentResolutionScale = Self.demotedResolutionScale(
                    currentFrameRate: signal.currentFrameRate,
                    demoteSamples: consecutiveDemoteSamples,
                    currentResolutionScale: currentResolutionScale
                )
            } else if consecutiveDemoteSamples >= Self.demoteSamplesRequired {
                state = .demoted
                currentResolutionScale = Self.demotedResolutionScale(
                    currentFrameRate: signal.currentFrameRate,
                    demoteSamples: consecutiveDemoteSamples,
                    currentResolutionScale: currentResolutionScale
                )
            } else {
                state = .stressed
            }
        case .jitter,
             .loss,
             .reassemblyBacklog,
             .pFrameLatency,
             .decodePressure,
             .presentationBacklog,
             .presentationFillDeficit,
             .presentationUnderflow:
            consecutiveStableSamples = 0
            consecutiveStressSamples += 1
            if trigger.demotesCadence {
                consecutiveDemoteSamples += 1
            } else {
                consecutiveDemoteSamples = 0
            }
            if consecutiveStressSamples >= Self.stressSamplesRequired || state == .recovering {
                state = .stressed
            }
            if consecutiveDemoteSamples >= Self.survivalSamplesRequired {
                state = .demoted
                currentResolutionScale = Self.demotedResolutionScale(
                    currentFrameRate: signal.currentFrameRate,
                    demoteSamples: consecutiveDemoteSamples,
                    currentResolutionScale: currentResolutionScale
                )
            } else if consecutiveDemoteSamples >= Self.demoteSamplesRequired {
                state = .demoted
                currentResolutionScale = Self.demotedResolutionScale(
                    currentFrameRate: signal.currentFrameRate,
                    demoteSamples: consecutiveDemoteSamples,
                    currentResolutionScale: currentResolutionScale
                )
            }
        case .startup:
            consecutiveStableSamples = 0
            consecutiveStressSamples = 0
            consecutiveDemoteSamples = 0
            state = .awaitingFirstFrame
        case .nonAwdl:
            state = .steady
        }

        return Self.decision(
            state: state,
            trigger: trigger,
            signal: signal,
            playoutDelayMs: updatePlayoutDelay(trigger: trigger, signal: signal),
            resolutionScale: currentResolutionScale,
            qualityReductionAllowed: state == .demoted &&
                consecutiveDemoteSamples >= Self.survivalSamplesRequired &&
                signal.currentFrameRate <= 30 &&
                currentResolutionScale <= 0.751
        )
    }

    private static func demotedResolutionScale(
        currentFrameRate: Int,
        demoteSamples: Int,
        currentResolutionScale: Double
    ) -> Double {
        guard currentFrameRate <= 30 else { return 1.0 }
        if demoteSamples >= Self.survivalSamplesRequired {
            return 0.75
        }
        if demoteSamples >= Self.demoteSamplesRequired {
            return min(currentResolutionScale, 0.875)
        }
        return currentResolutionScale
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
            presentationStallCount: signal.presentationStallCount,
            recoveryState: signal.recoveryState
        )
        let frameIntervalMs = 1_000.0 / Double(max(1, signal.currentFrameRate))
        let fillDeficitDelayMs = signal.presentationFillDeficitFrames > 0
            ? min(
                Self.stableMaximumPlayoutDelayMs,
                Self.basePlayoutDelayMs + frameIntervalMs * Double(min(signal.presentationFillDeficitFrames, 4))
            )
            : Self.basePlayoutDelayMs
        switch trigger {
        case .stable, .startup:
            if currentPlayoutDelayMs <= Self.basePlayoutDelayMs {
                currentPlayoutDelayMs = Self.basePlayoutDelayMs
            } else if consecutiveStableSamples >= Self.stableSamplesForSteady {
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
             .presentationBacklog,
             .presentationFillDeficit,
             .presentationUnderflow,
             .recovery,
             .demote:
            currentPlayoutDelayMs = min(
                Self.maximumPlayoutDelayMs,
                max(currentPlayoutDelayMs, measuredDelayMs, fillDeficitDelayMs)
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
        let requestedFrameRate = signal.requestedFrameRateCeiling ?? max(
            signal.currentFrameRate,
            signal.targetFrameRate
        )
        let targetFrameRate = interactiveDisplayTargetFrameRate(
            requestedFrameRate: requestedFrameRate,
            mediaPathProfile: signal.mediaPathProfile
        )
        let clampedResolutionScale = min(1.0, max(0.75, resolutionScale))
        return Decision(
            state: state,
            trigger: trigger,
            targetFrameRate: targetFrameRate,
            resolutionScale: clampedResolutionScale,
            hostPacingBudgetBps: pacingBudgetBps(targetBitrateBps: signal.targetBitrateBps),
            keyframePacingBudgetBps: keyframePacingBudgetBps(
                targetBitrateBps: signal.targetBitrateBps,
                state: state
            ),
            pFramePacketBurst: pFramePacketBurst,
            keyframePacketBurst: keyframePacketBurst,
            pFrameFECBlockSize: pFrameFECBlockSize(
                frameByteCount: signal.reassemblyBacklogBytes,
                maxPayloadSize: 1_200,
                isLossModeActive: trigger == .loss ||
                    state == .awaitingFirstFrame ||
                    state == .recovering ||
                    state == .failed
            ),
            keyframeFECBlockSize: keyframeFECBlockSize(),
            continuityWindowMs: continuityWindowMs(
                pFrameCompletionLatencyP95Ms: signal.pFrameCompletionLatencyP95Ms ?? 0,
                latePFrameCount: signal.latePFrameCount
            ),
            playoutDelayMs: playoutDelayMs,
            pacingHoldSeconds: pacingHoldSeconds,
            qualityReductionAllowed: qualityReductionAllowed,
            selectedLever: selectedLever(
                state: state,
                trigger: trigger,
                resolutionScale: clampedResolutionScale,
                playoutDelayMs: playoutDelayMs,
                qualityReductionAllowed: qualityReductionAllowed,
                mediaPathProfile: signal.mediaPathProfile
            )
        )
    }

    private static func selectedLever(
        state: State,
        trigger: Trigger,
        resolutionScale: Double,
        playoutDelayMs: Double,
        qualityReductionAllowed: Bool,
        mediaPathProfile: MirageMediaPathProfile
    ) -> SelectedLever {
        guard mediaPathProfile.usesAwdlRadioPolicy else { return .observe }
        if state == .recovering ||
            state == .failed ||
            state == .awaitingFirstFrame ||
            trigger == .recovery ||
            trigger == .startup {
            return .recovery
        }
        if qualityReductionAllowed {
            return .quality
        }
        if resolutionScale < 1.0 {
            return .resolution
        }
        if playoutDelayMs > basePlayoutDelayMs {
            return .playout
        }
        if trigger != .stable && trigger != .nonAwdl {
            return .pacing
        }
        return .observe
    }

    private static func interactiveDisplayTargetFrameRate(
        requestedFrameRate: Int,
        mediaPathProfile: MirageMediaPathProfile
    ) -> Int {
        guard mediaPathProfile.usesAwdlRadioPolicy else { return max(1, requestedFrameRate) }
        return awdlRadioFrameRate
    }

    private static func trigger(for signal: Signal) -> Trigger {
        guard signal.mediaPathProfile.usesAwdlRadioPolicy else { return .nonAwdl }
        if signal.recoveryState == .startup || signal.recoveryState == .postResizeAwaitingFirstFrame {
            return .startup
        }
        if signal.recoveryState != .idle || signal.forwardGapTimeouts > 0 {
            return .recovery
        }

        let currentFrameRate = max(signal.currentFrameRate, signal.targetFrameRate)
        let frameIntervalMs = 1_000.0 / Double(max(1, currentFrameRate))
        let jitterStress = signal.jitterP99Ms >= max(60.0, frameIntervalMs * 4.0)
        let unrepairedMissingFragments = signal.missingFragmentTimeouts > signal.fecRecoveredFragmentCount
        let lossStress = signal.lostFrameCount >= 6 ||
            signal.discardedPacketCount >= 6 ||
            unrepairedMissingFragments
        let keyframeLatencyStress = (signal.keyframeCompletionLatencyP95Ms ?? 0) >= max(120.0, frameIntervalMs * 6.0)
        let reassemblyBacklogStress = signal.reassemblyBacklogFrames >= 8 ||
            signal.reassemblyBacklogBytes >= 2_000_000 ||
            keyframeLatencyStress
        let receiverPlayoutTargetMs = signal.receiverPlayoutDelayTargetMs ?? Self.basePlayoutDelayMs
        let pFrameLatencyThresholdMs = max(
            50.0,
            frameIntervalMs * 3.0,
            min(Self.maximumPlayoutDelayMs, receiverPlayoutTargetMs) + frameIntervalMs
        )
        let pFrameLatencyStress = (signal.pFrameCompletionLatencyP95Ms ?? 0) >= pFrameLatencyThresholdMs ||
            signal.latePFrameCount >= 4
        let decodeSubmissionLimit = signal.decodeSubmissionLimit ?? 0
        let inFlightDecodeSubmissions = signal.inFlightDecodeSubmissions ?? 0
        let decodeSubmissionSaturated = decodeSubmissionLimit > 0 &&
            inFlightDecodeSubmissions >= decodeSubmissionLimit
        let decodeThroughputGap = max(0, signal.receivedFPS - signal.decodedFPS)
        let decodeThroughputPressure = signal.receivedFPS > 0 &&
            signal.decodedFPS < Double(currentFrameRate) * 0.85 &&
            decodeThroughputGap >= 2.5
        let decodePressure = signal.decodeBacklogFrames >= 4 ||
            (decodeSubmissionSaturated && decodeThroughputPressure)
        let presentationBacklogPressure = signal.presentationBacklogFrames >= 4
        let presentationFillDeficitPressure = signal.presentationFillDeficitFrames >= 2
        let displayUnderflowTickThreshold = UInt64(max(3, currentFrameRate / 20))
        let presentationUnderflow = signal.presentationStallCount > 0 ||
            signal.displayTickNoFrameCount >= displayUnderflowTickThreshold ||
            signal.pendingFrameNotReadyDisplayTickCount >= displayUnderflowTickThreshold

        if lossStress { return .loss }
        if reassemblyBacklogStress { return .reassemblyBacklog }
        if pFrameLatencyStress { return .pFrameLatency }
        if decodePressure { return .decodePressure }
        if presentationBacklogPressure { return .presentationBacklog }
        if presentationUnderflow { return .presentationUnderflow }
        if presentationFillDeficitPressure { return .presentationFillDeficit }
        if jitterStress { return .jitter }
        return .stable
    }
}

private extension MirageAwdlMediaController.Trigger {
    var demotesCadence: Bool {
        switch self {
        case .reassemblyBacklog,
             .pFrameLatency,
             .jitter,
             .loss,
             .decodePressure,
             .presentationBacklog,
             .presentationUnderflow,
             .demote:
            true
        case .startup,
             .stable,
             .presentationFillDeficit,
             .recovery,
             .nonAwdl:
            false
        }
    }
}
