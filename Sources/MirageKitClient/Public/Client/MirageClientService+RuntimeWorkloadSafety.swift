//
//  MirageClientService+RuntimeWorkloadSafety.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/7/26.
//
//  Runtime workload safety policy for client memory pressure.
//

import CoreGraphics
import Foundation
import MirageKit

#if os(iOS) && canImport(UIKit)
import UIKit
#endif

/// Client-side stall categories considered by runtime workload safety.
enum RuntimeWorkloadSafetyStallEvent: Equatable {
    /// Rendering recovered after the presenter detected stalled presentation.
    case presentationRecovery

    /// Keyframe recovery was requested because decode could not progress.
    case keyframeStarved

    /// Media packet arrival stalled before decode could proceed.
    case packetStarved

    /// Client rendering capacity appears to be the bottleneck.
    case clientRenderCapacity
}

/// Temporary frame-rate cap for a single stream.
struct RuntimeWorkloadSafetyFrameRateCap: Equatable {
    /// Maximum target frame rate allowed while the cap is active.
    let frameRate: Int

    /// Absolute time when the cap should be pruned.
    let expiresAt: CFAbsoluteTime
}

@MainActor
extension MirageClientService {
    /// Reason a runtime workload-safety cap was applied.
    enum RuntimeWorkloadSafetyFallbackReason: String {
        /// First memory-pressure event reduced stream workload.
        case memoryPressure = "memory_pressure"

        /// Repeated memory pressure escalated the reduction.
        case repeatedMemoryPressure = "repeated_memory_pressure"

        /// Repeated high-refresh presentation stalls triggered a frame-rate cap.
        case promotionStall = "promotion_stall"
    }

    nonisolated static let runtimeWorkloadSafetyMinimumFrameRate = 30
    nonisolated static let runtimeWorkloadSafetyMemoryPressureRepeatWindow: CFAbsoluteTime = 600
    nonisolated static let runtimeWorkloadSafetyProMotionStallWindow: CFAbsoluteTime = 300
    nonisolated static let runtimeWorkloadSafetyProMotionStallThreshold = 2
    nonisolated static let runtimeWorkloadSafetyFrameRateCapDuration: CFAbsoluteTime = 120

    /// Current runtime frame-rate cap applied across active streams, if workload safety has clamped one.
    public var runtimeWorkloadFrameRateCap: Int? {
        runtimeWorkloadSafetyEffectiveFrameRateCap
    }

    /// Reason for the current workload-safety fallback, if a cap is active.
    public var runtimeWorkloadFallbackReason: String? {
        runtimeWorkloadSafetyLastFallbackReason
    }

    /// Number of memory-pressure events handled since the current client session began.
    public var runtimeMemoryPressureCount: Int {
        runtimeWorkloadSafetyMemoryPressureCount
    }

    /// Age in seconds of the most recent handled memory-pressure event.
    public var runtimeMemoryPressureLastAgeSeconds: Double? {
        runtimeWorkloadSafetyLastMemoryPressureTime.map {
            max(0, CFAbsoluteTimeGetCurrent() - $0)
        }
    }

    /// Applies runtime safety backoff after the app receives a memory-pressure signal.
    public func handleMemoryPressure() async {
        await handleRuntimeWorkloadSafetyMemoryPressure()
    }

    func handleRuntimeWorkloadSafetyMemoryPressure() async {
        let now = CFAbsoluteTimeGetCurrent()
        let repeatedPressure = runtimeWorkloadSafetyLastMemoryPressureTime
            .map { now - $0 <= Self.runtimeWorkloadSafetyMemoryPressureRepeatWindow } ?? false
        runtimeWorkloadSafetyMemoryPressureCount += 1
        runtimeWorkloadSafetyLastMemoryPressureTime = now

        let streamIDs = activeInteractiveStreamIDs
        var trimmedStreamCount = 0

        for streamID in streamIDs {
            guard let controller = controllersByStream[streamID] else { continue }
            if await controller.handleMemoryPressure(resetDecoder: repeatedPressure) {
                trimmedStreamCount += 1
            }
        }

        let highestFrameRate = streamIDs
            .map { runtimeWorkloadSafetyCurrentFrameRate(for: $0) }
            .max() ?? screenMaxRefreshRate
        let targetFrameRate = Self.runtimeWorkloadSafetyMemoryPressureTarget(
            currentFrameRate: highestFrameRate,
            repeated: repeatedPressure
        )

        if let targetFrameRate {
            await applyRuntimeWorkloadSafetyCap(
                targetFrameRate: targetFrameRate,
                reason: repeatedPressure ? .repeatedMemoryPressure : .memoryPressure,
                triggerStreamID: nil
            )
        }

        let fallbackText = targetFrameRate.map { "\($0)fps" } ?? "none"
        MirageLogger.client(
            "Handled client memory pressure: activeStreams=\(streamIDs.count), " +
                "trimmedStreams=\(trimmedStreamCount), repeated=\(repeatedPressure), " +
                "fallback=\(fallbackText)"
        )
    }

    func handleRuntimeWorkloadSafetyStallEvent(
        streamID: StreamID,
        event: RuntimeWorkloadSafetyStallEvent
    ) {
        guard Self.runtimeWorkloadSafetyShouldUseIPadProMotionFallback() else { return }
        guard Self.runtimeWorkloadSafetyStallEventAllowsFrameRateFallback(event) else { return }
        guard runtimeWorkloadSafetyTransportIsClean(for: streamID) else { return }
        guard runtimeWorkloadSafetyHostSourceIsHealthy(for: streamID) else { return }

        let currentFrameRate = runtimeWorkloadSafetyCurrentFrameRate(for: streamID)
        guard currentFrameRate >= 90 else { return }

        let now = CFAbsoluteTimeGetCurrent()
        let recentStalls = (runtimeWorkloadSafetyStallTimesByStream[streamID] ?? [])
            .filter { now - $0 <= Self.runtimeWorkloadSafetyProMotionStallWindow } + [now]
        runtimeWorkloadSafetyStallTimesByStream[streamID] = recentStalls

        guard let targetFrameRate = Self.runtimeWorkloadSafetyProMotionStallTarget(
            currentFrameRate: currentFrameRate,
            recentStallCount: recentStalls.count
        ) else {
            return
        }

        runtimeWorkloadSafetyStallTimesByStream[streamID] = []
        Task { @MainActor [weak self] in
            guard let self else { return }
            await applyRuntimeWorkloadSafetyCap(
                targetFrameRate: targetFrameRate,
                reason: .promotionStall,
                triggerStreamID: streamID
            )
        }
    }

    func applyRuntimeWorkloadSafetyCap(
        targetFrameRate: Int,
        reason: RuntimeWorkloadSafetyFallbackReason,
        triggerStreamID: StreamID?
    )
    async {
        let normalizedTarget = max(
            Self.runtimeWorkloadSafetyMinimumFrameRate,
            MirageRenderModePolicy.normalizedTargetFPS(targetFrameRate)
        )
        let now = CFAbsoluteTimeGetCurrent()
        let streamIDs = triggerStreamID.map { [$0] } ?? activeInteractiveStreamIDs
        var appliedCount = 0
        var failedCount = 0
        for streamID in streamIDs {
            let existingCap = runtimeWorkloadSafetyFrameRateCap(for: streamID)
            let effectiveCap = min(existingCap ?? normalizedTarget, normalizedTarget)
            runtimeWorkloadSafetyFrameRateCapsByStream[streamID] = RuntimeWorkloadSafetyFrameRateCap(
                frameRate: effectiveCap,
                expiresAt: now + Self.runtimeWorkloadSafetyFrameRateCapDuration
            )
            runtimeWorkloadSafetyLastFallbackReason = reason.rawValue
            let currentFrameRate = runtimeWorkloadSafetyCurrentFrameRate(for: streamID)
            guard currentFrameRate > effectiveCap ||
                (refreshRateOverridesByStream[streamID] ?? 0) > effectiveCap ||
                (observedFrameRateByStream[streamID] ?? 0) > effectiveCap else {
                continue
            }

            do {
                try await sendStreamEncoderSettingsChange(
                    streamID: streamID,
                    targetFrameRate: effectiveCap
                )
                appliedCount += 1
            } catch {
                failedCount += 1
                await applyStreamCadenceTarget(
                    effectiveCap,
                    for: streamID,
                    reason: "runtime workload fallback"
                )
                MirageLogger.client(
                    "Runtime workload fallback failed for stream \(streamID): " +
                        "\(error.localizedDescription)"
                )
            }
        }

        let triggerText = triggerStreamID.map { " stream=\($0)" } ?? ""
        MirageLogger.client(
            "Runtime workload safety cap active: \(normalizedTarget)fps reason=\(reason.rawValue)" +
                "\(triggerText) updatedStreams=\(appliedCount) failedStreams=\(failedCount)"
        )
    }

    func resetRuntimeWorkloadSafetyState() {
        runtimeWorkloadSafetyFrameRateCapsByStream.removeAll(keepingCapacity: false)
        runtimeWorkloadSafetyLastFallbackReason = nil
        runtimeWorkloadSafetyMemoryPressureCount = 0
        runtimeWorkloadSafetyLastMemoryPressureTime = nil
        runtimeWorkloadSafetyStallTimesByStream.removeAll(keepingCapacity: false)
    }

    func clearRuntimeWorkloadSafetyState(for streamID: StreamID) {
        runtimeWorkloadSafetyStallTimesByStream.removeValue(forKey: streamID)
        runtimeWorkloadSafetyFrameRateCapsByStream.removeValue(forKey: streamID)
    }

    func runtimeWorkloadSafetyFrameRateCap(for streamID: StreamID) -> Int? {
        pruneExpiredRuntimeWorkloadSafetyCaps()
        return runtimeWorkloadSafetyFrameRateCapsByStream[streamID]?.frameRate
    }

    /// Lowest non-expired frame-rate cap currently enforced by runtime workload safety.
    var runtimeWorkloadSafetyEffectiveFrameRateCap: Int? {
        pruneExpiredRuntimeWorkloadSafetyCaps()
        return runtimeWorkloadSafetyFrameRateCapsByStream.values.map(\.frameRate).min()
    }

    private func pruneExpiredRuntimeWorkloadSafetyCaps(now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) {
        runtimeWorkloadSafetyFrameRateCapsByStream = runtimeWorkloadSafetyFrameRateCapsByStream.filter { entry in
            entry.value.expiresAt > now
        }
        if runtimeWorkloadSafetyFrameRateCapsByStream.isEmpty {
            runtimeWorkloadSafetyLastFallbackReason = nil
        }
    }

    func runtimeWorkloadSafetyCurrentFrameRate(for streamID: StreamID) -> Int {
        if let snapshot = metricsStore.snapshot(for: streamID), snapshot.hostTargetFrameRate > 0 {
            return MirageRenderModePolicy.normalizedTargetFPS(snapshot.hostTargetFrameRate)
        }
        if let observed = observedFrameRateByStream[streamID], observed > 0 {
            return MirageRenderModePolicy.normalizedTargetFPS(observed)
        }
        if let override = refreshRateOverridesByStream[streamID], override > 0 {
            return MirageRenderModePolicy.normalizedTargetFPS(override)
        }
        return screenMaxRefreshRate
    }

    func runtimeWorkloadSafetyTransportIsClean(for streamID: StreamID) -> Bool {
        guard let snapshot = metricsStore.snapshot(for: streamID), snapshot.hasHostMetrics else { return false }
        let assessment = MirageTransportPressure.assess(
            sample: MirageTransportPressureSample(
                queueBytes: max(0, snapshot.hostSendQueueBytes ?? 0),
                queueStressBytes: 800_000,
                packetPacerAverageSleepMs: max(0, snapshot.hostPacketPacerAverageSleepMs ?? 0),
                packetPacerStressThresholdMs: 0.75,
                sendStartDelayAverageMs: max(0, snapshot.hostSendStartDelayAverageMs ?? 0),
                sendStartDelayStressThresholdMs: 2.0,
                sendCompletionAverageMs: max(0, snapshot.hostSendCompletionAverageMs ?? 0),
                sendCompletionStressThresholdMs: 12.0,
                transportDropCount: snapshot.hostStalePacketDrops ?? 0
            )
        )
        return !assessment.primaryStress && !assessment.isDelayOnlyBurst
    }

    func runtimeWorkloadSafetyHostSourceIsHealthy(for streamID: StreamID) -> Bool {
        guard let snapshot = metricsStore.snapshot(for: streamID), snapshot.hasHostMetrics else { return false }
        let targetFPS = Double(max(1, snapshot.hostTargetFrameRate > 0 ? snapshot.hostTargetFrameRate : 60))
        if snapshot.hostCaptureVirtualDisplayTimingSuspect == true { return false }
        let cadenceFloor = targetFPS * 0.90
        let lowHostCadence = [
            snapshot.hostCaptureIngressFPS,
            snapshot.hostCaptureFPS,
            snapshot.hostEncodeAttemptFPS,
        ].contains { value in
            guard let value, value > 0 else { return false }
            return value < cadenceFloor
        }
        if lowHostCadence { return false }

        let frameBudgetMs = 1000.0 / targetFPS
        let p99Gap = max(
            snapshot.hostCaptureDeliveredFrameGapP99Ms ?? 0,
            snapshot.hostCaptureWallClockGapP99Ms ?? 0,
            snapshot.hostCaptureDisplayTimeGapP99Ms ?? 0
        )
        let worstGap = max(
            snapshot.hostCaptureDeliveredFrameGapWorstMs ?? 0,
            snapshot.hostCaptureWallClockGapWorstMs ?? 0,
            snapshot.hostCaptureDisplayTimeGapWorstMs ?? 0
        )
        if p99Gap >= max(35.0, frameBudgetMs * 2.0) { return false }
        if worstGap >= max(70.0, frameBudgetMs * 4.0) { return false }
        if (snapshot.hostCaptureLongFrameGapCount ?? 0) > 0 { return false }
        return true
    }

    nonisolated static func runtimeWorkloadSafetyMemoryPressureTarget(
        currentFrameRate: Int,
        repeated: Bool
    ) -> Int? {
        let currentFrameRate = max(0, currentFrameRate)
        if repeated {
            return currentFrameRate > runtimeWorkloadSafetyMinimumFrameRate ?
                runtimeWorkloadSafetyMinimumFrameRate :
                nil
        }
        if currentFrameRate > 60 { return 60 }
        if currentFrameRate > runtimeWorkloadSafetyMinimumFrameRate {
            return runtimeWorkloadSafetyMinimumFrameRate
        }
        return nil
    }

    nonisolated static func runtimeWorkloadSafetyProMotionStallTarget(
        currentFrameRate: Int,
        recentStallCount: Int
    ) -> Int? {
        guard recentStallCount >= runtimeWorkloadSafetyProMotionStallThreshold else { return nil }
        let currentFrameRate = max(0, currentFrameRate)
        if currentFrameRate >= 90 { return 60 }
        return nil
    }

    nonisolated static func runtimeWorkloadSafetyStallEventAllowsFrameRateFallback(
        _ event: RuntimeWorkloadSafetyStallEvent
    ) -> Bool {
        switch event {
        case .clientRenderCapacity, .presentationRecovery:
            true
        case .keyframeStarved, .packetStarved:
            false
        }
    }

    nonisolated static func runtimeWorkloadSafetyCappedFrameRate(_ frameRate: Int, cap: Int?) -> Int {
        let normalizedFrameRate = MirageRenderModePolicy.normalizedTargetFPS(frameRate)
        guard let cap else { return normalizedFrameRate }
        let normalizedCap = MirageRenderModePolicy.normalizedTargetFPS(cap)
        return min(normalizedFrameRate, normalizedCap)
    }

    nonisolated static func runtimeWorkloadSafetyCappedTier(
        _ tier: MirageAutomaticDesktopWorkloadTier,
        cap: Int?
    ) -> MirageAutomaticDesktopWorkloadTier {
        let cappedFrameRate = runtimeWorkloadSafetyCappedFrameRate(tier.targetFrameRate, cap: cap)
        guard cappedFrameRate != tier.targetFrameRate else { return tier }
        return MirageAutomaticDesktopWorkloadTier(
            encodedPixelSize: tier.encodedPixelSize,
            targetFrameRate: cappedFrameRate
        )
    }

    nonisolated static func runtimeWorkloadSafetyShouldUseIPadProMotionFallback() -> Bool {
        #if os(iOS) && canImport(UIKit)
        return UIDevice.current.userInterfaceIdiom == .pad
        #else
        return false
        #endif
    }
}
