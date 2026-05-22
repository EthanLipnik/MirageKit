//
//  HostCaptureCadenceRecoveryPolicy.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/3/26.
//
//  Conservative recovery policy for sustained host capture cadence stalls.
//

import Foundation
import MirageKit

#if os(macOS)
struct HostCaptureCadenceRecoveryPolicy: Sendable {
    enum Action: Sendable, Equatable {
        case none
        case restartVirtualDisplayCadenceDriver
        case restartCapture
        case reassertVirtualDisplayMode
        case recreateVirtualDisplay
    }

    enum SuppressionReason: Sendable, Equatable {
        case receiverAlreadyPresented
    }

    struct Configuration: Sendable, Equatable {
        var consecutiveBadWindowsRequired: Int = 2
        var goodWindowsRequiredToResetEscalation: Int = 3
        var cadenceDriverRestartsBeforeReassert: Int = 2
        var captureRestartsBeforeReassert: Int = 0
        var virtualDisplayReassertsBeforeRecreate: Int = 2
        var actionCooldownSeconds: CFAbsoluteTime = 8.0
        var captureFPSFloorRatio: Double = 0.90
        var captureGapP99MinimumMs: Double = 30.0
        var captureGapP99FrameMultiplier: Double = 1.8
        var captureGapWorstMinimumMs: Double = 70.0
        var captureGapWorstFrameMultiplier: Double = 4.0
        var displayTimeDriftCountThreshold: UInt64 = 2
        var lowQueueMinimumBytes: Int = 64 * 1024
        var lowQueuePressureRatio: Double = 0.5
        var encodeHealthyFrameBudgetMultiplier: Double = 1.05
        var sendStartHealthyMinimumMs: Double = 35.0
        var sendStartHealthyFrameMultiplier: Double = 2.0
        var sendCompletionHealthyMinimumMs: Double = 50.0
        var sendCompletionHealthyFrameMultiplier: Double = 3.0
        var severeCaptureGapMs: Double = 500.0
        var highRefreshTargetFrameRate: Int = 90
        var highRefreshPolicyRateMismatchRatio: Double = 0.85
    }

    struct Sample: Sendable {
        var now: CFAbsoluteTime
        var isDesktopDisplayStream: Bool
        var startupSettled: Bool
        var receiverHasPresentedFrame: Bool
        var isResizing: Bool
        var isEncodingSuspendedForResize: Bool
        var targetFrameRate: Int
        var captureFPS: Double?
        var captureIngressFPS: Double?
        var encodeAttemptFPS: Double?
        var averageEncodeMs: Double?
        var frameBudgetMs: Double
        var sendQueueBytes: Int?
        var queuePressureBytes: Int
        var sendStartDelayMaxMs: Double?
        var sendCompletionMaxMs: Double?
        var packetPacerFrameMaxSleepMs: Int?
        var captureCadence: StreamCaptureCadenceMetrics?
    }

    var configuration = Configuration()
    private var badWindowCount = 0
    private var goodWindowCount = 0
    private var cadenceDriverRestartCount = 0
    private var captureRestartCount = 0
    private var virtualDisplayReassertCount = 0
    private var lastActionTime: CFAbsoluteTime = 0
    private(set) var lastSuppressedAction: Action?
    private(set) var lastSuppressionReason: SuppressionReason?

    mutating func reset() {
        badWindowCount = 0
        goodWindowCount = 0
        cadenceDriverRestartCount = 0
        captureRestartCount = 0
        virtualDisplayReassertCount = 0
        lastActionTime = 0
        lastSuppressedAction = nil
        lastSuppressionReason = nil
    }

    mutating func evaluate(_ sample: Sample) -> Action {
        lastSuppressedAction = nil
        lastSuppressionReason = nil

        guard sample.isDesktopDisplayStream,
              sample.startupSettled,
              !sample.isResizing,
              !sample.isEncodingSuspendedForResize else {
            badWindowCount = 0
            goodWindowCount = 0
            return .none
        }

        let cadenceBad = Self.captureCadenceIsBad(sample, configuration: configuration)
        let downstreamHealthy = Self.downstreamIsHealthy(sample, configuration: configuration)

        guard cadenceBad, downstreamHealthy else {
            badWindowCount = 0
            if cadenceBad {
                goodWindowCount = 0
            } else {
                goodWindowCount += 1
                if goodWindowCount >= configuration.goodWindowsRequiredToResetEscalation {
                    cadenceDriverRestartCount = 0
                    captureRestartCount = 0
                    virtualDisplayReassertCount = 0
                }
            }
            return .none
        }

        if Self.hasSeverePresentedDesktopCaptureStall(sample, configuration: configuration) {
            guard lastActionTime <= 0 || sample.now - lastActionTime >= configuration.actionCooldownSeconds else {
                return .none
            }
            badWindowCount = 0
            goodWindowCount = 0
            lastActionTime = sample.now
            captureRestartCount += 1
            return .restartCapture
        }

        if let immediateAction = Self.highRefreshImmediateRecoveryAction(sample, configuration: configuration) {
            guard lastActionTime <= 0 || sample.now - lastActionTime >= configuration.actionCooldownSeconds else {
                return .none
            }
            guard recordAndAllowAction(immediateAction, receiverHasPresentedFrame: sample.receiverHasPresentedFrame) else {
                return .none
            }
            badWindowCount = 0
            goodWindowCount = 0
            lastActionTime = sample.now
            switch immediateAction {
            case .restartVirtualDisplayCadenceDriver:
                cadenceDriverRestartCount += 1
            case .restartCapture:
                captureRestartCount += 1
            case .reassertVirtualDisplayMode:
                virtualDisplayReassertCount += 1
            case .recreateVirtualDisplay, .none:
                break
            }
            return immediateAction
        }

        goodWindowCount = 0
        badWindowCount += 1
        guard badWindowCount >= configuration.consecutiveBadWindowsRequired else { return .none }
        if lastActionTime > 0, sample.now - lastActionTime < configuration.actionCooldownSeconds {
            return .none
        }

        badWindowCount = 0
        lastActionTime = sample.now
        if sample.receiverHasPresentedFrame {
            captureRestartCount += 1
            return .restartCapture
        }
        if cadenceDriverRestartCount < configuration.cadenceDriverRestartsBeforeReassert {
            cadenceDriverRestartCount += 1
            return .restartVirtualDisplayCadenceDriver
        }
        if captureRestartCount < configuration.captureRestartsBeforeReassert {
            captureRestartCount += 1
            return .restartCapture
        }
        if virtualDisplayReassertCount < configuration.virtualDisplayReassertsBeforeRecreate {
            virtualDisplayReassertCount += 1
            return .reassertVirtualDisplayMode
        }
        return .recreateVirtualDisplay
    }

    private mutating func recordAndAllowAction(
        _ action: Action,
        receiverHasPresentedFrame: Bool
    ) -> Bool {
        _ = action
        _ = receiverHasPresentedFrame
        return true
    }

    private static func captureCadenceIsBad(
        _ sample: Sample,
        configuration: Configuration
    ) -> Bool {
        let targetFPS = effectiveHealthFrameRate(sample)
        let fpsFloor = targetFPS * configuration.captureFPSFloorRatio
        let observedCaptureRates = [
            sample.captureFPS,
            sample.captureIngressFPS,
        ].compactMap { value -> Double? in
            guard let value, value > 0 else { return nil }
            return value
        }
        let lowCaptureFPS = if let observedCaptureFPS = observedCaptureRates.max() {
            observedCaptureFPS < fpsFloor
        } else {
            sample.encodeAttemptFPS.map { $0 > 0 && $0 < fpsFloor } ?? false
        }

        let cadence = sample.captureCadence
        let p99Gap = largest(
            cadence?.wallClockGapP99Ms,
            cadence?.displayTimeGapP99Ms,
            cadence?.deliveredFrameGapP99Ms
        )
        let worstGap = largest(
            cadence?.wallClockGapWorstMs,
            cadence?.displayTimeGapWorstMs,
            cadence?.deliveredFrameGapWorstMs
        )
        let p99Threshold = max(
            configuration.captureGapP99MinimumMs,
            sample.frameBudgetMs * configuration.captureGapP99FrameMultiplier
        )
        let worstThreshold = max(
            configuration.captureGapWorstMinimumMs,
            sample.frameBudgetMs * configuration.captureGapWorstFrameMultiplier
        )
        let highP99Gap = p99Gap.map { $0 >= p99Threshold } ?? false
        let highWorstGap = worstGap.map { $0 >= worstThreshold } ?? false
        let repeatedDisplayDrift = (cadence?.displayTimeDriftCount ?? 0) >=
            configuration.displayTimeDriftCountThreshold
        let statusLimited = (cadence?.blankFrameStatusCount ?? 0) > 0 ||
            (cadence?.suspendedFrameStatusCount ?? 0) > 0 ||
            (cadence?.stoppedFrameStatusCount ?? 0) > 0
        let explicitDrops = (cadence?.longFrameGapCount ?? 0) > 0 ||
            (cadence?.cadenceDropCount ?? 0) > 0
        let virtualTimingSuspect = cadence?.virtualDisplayTimingSuspect == true
        let highRefreshPolicyMismatch = highRefreshPolicyRateMismatch(sample, configuration: configuration)

        return lowCaptureFPS ||
            highP99Gap ||
            highWorstGap ||
            repeatedDisplayDrift ||
            statusLimited ||
            explicitDrops ||
            virtualTimingSuspect ||
            highRefreshPolicyMismatch
    }

    private static func highRefreshImmediateRecoveryAction(
        _ sample: Sample,
        configuration: Configuration
    ) -> Action? {
        guard sample.targetFrameRate >= configuration.highRefreshTargetFrameRate,
              let observedCaptureFPS = [
                  sample.captureFPS,
                  sample.captureIngressFPS,
              ].compactMap({ value -> Double? in
                  guard let value, value > 0 else { return nil }
                  return value
              }).max() ?? sample.encodeAttemptFPS else {
            return nil
        }

        if highRefreshPolicyRateMismatch(sample, configuration: configuration) {
            return .reassertVirtualDisplayMode
        }
        let healthFPS = effectiveHealthFrameRate(sample)
        guard observedCaptureFPS < healthFPS * configuration.captureFPSFloorRatio else { return nil }
        return .restartCapture
    }

    private static func hasSeverePresentedDesktopCaptureStall(
        _ sample: Sample,
        configuration: Configuration
    ) -> Bool {
        guard sample.receiverHasPresentedFrame,
              let cadence = sample.captureCadence else {
            return false
        }
        if cadence.virtualDisplayTimingSuspect == true {
            return true
        }
        let severeGap = largest(
            cadence.wallClockGapWorstMs,
            cadence.displayTimeGapWorstMs,
            cadence.deliveredFrameGapWorstMs
        ) ?? 0
        return severeGap >= configuration.severeCaptureGapMs
    }

    private static func highRefreshPolicyRateMismatch(
        _ sample: Sample,
        configuration: Configuration
    ) -> Bool {
        guard let cadence = sample.captureCadence else { return false }
        let targetFPS = Double(max(1, sample.targetFrameRate))
        let expectedFloor = targetFPS * configuration.highRefreshPolicyRateMismatchRatio
        guard (cadence.virtualDisplayRefreshRate ?? 0) >= expectedFloor else { return false }

        let observedPolicyRate = [
            cadence.displayRefreshRate.map { Double($0) },
            cadence.minimumFrameIntervalRate.map { Double($0) },
        ].compactMap { $0 }.min()
        guard let observedPolicyRate else { return false }
        return observedPolicyRate < expectedFloor
    }

    private static func downstreamIsHealthy(
        _ sample: Sample,
        configuration: Configuration
    ) -> Bool {
        let queuePressureBytes = max(0, sample.queuePressureBytes)
        let lowQueueLimit = max(
            configuration.lowQueueMinimumBytes,
            Int(Double(queuePressureBytes) * configuration.lowQueuePressureRatio)
        )
        let queueHealthy = (sample.sendQueueBytes ?? 0) <= lowQueueLimit
        let encodeHealthy = sample.averageEncodeMs.map {
            $0 <= sample.frameBudgetMs * configuration.encodeHealthyFrameBudgetMultiplier
        } ?? true
        let sendStartLimit = max(
            configuration.sendStartHealthyMinimumMs,
            sample.frameBudgetMs * configuration.sendStartHealthyFrameMultiplier
        )
        let sendCompletionLimit = max(
            configuration.sendCompletionHealthyMinimumMs,
            sample.frameBudgetMs * configuration.sendCompletionHealthyFrameMultiplier
        )
        let sendStartHealthy = sample.sendStartDelayMaxMs.map { $0 <= sendStartLimit } ?? true
        let sendCompletionHealthy = sample.sendCompletionMaxMs.map { $0 <= sendCompletionLimit } ?? true
        let pacerHealthy = sample.packetPacerFrameMaxSleepMs.map {
            Double($0) <= max(16.7, sample.frameBudgetMs)
        } ?? true

        return queueHealthy &&
            encodeHealthy &&
            sendStartHealthy &&
            sendCompletionHealthy &&
            pacerHealthy
    }

    private static func effectiveHealthFrameRate(_ sample: Sample) -> Double {
        let targetFrameRate = max(1, sample.targetFrameRate)
        return Double(targetFrameRate)
    }

    private static func largest(_ values: Double?...) -> Double? {
        var largestValue: Double?
        for value in values {
            guard let value else { continue }
            largestValue = max(largestValue ?? value, value)
        }
        return largestValue
    }
}
#endif
