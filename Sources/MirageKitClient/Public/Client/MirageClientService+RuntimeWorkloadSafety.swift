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

enum RuntimeWorkloadSafetyStallEvent: Sendable, Equatable {
    case presentationRecovery
    case keyframeStarved
    case packetStarved
    case clientRenderCapacity
}

struct RuntimeWorkloadSafetyFrameRateCap: Sendable, Equatable {
    let frameRate: Int
    let reason: MirageClientService.RuntimeWorkloadSafetyFallbackReason
    let appliedAt: CFAbsoluteTime
    let expiresAt: CFAbsoluteTime
}

@MainActor
extension MirageClientService {
    enum RuntimeWorkloadSafetyFallbackReason: String, Sendable {
        case memoryPressure = "memory_pressure"
        case repeatedMemoryPressure = "repeated_memory_pressure"
        case promotionStall = "promotion_stall"
    }

    nonisolated static let runtimeWorkloadSafetyMinimumFrameRate = 30
    nonisolated static let runtimeWorkloadSafetyMemoryPressureRepeatWindow: CFAbsoluteTime = 600
    nonisolated static let runtimeWorkloadSafetyProMotionStallWindow: CFAbsoluteTime = 300
    nonisolated static let runtimeWorkloadSafetyProMotionStallThreshold = 2
    nonisolated static let runtimeWorkloadSafetyFrameRateCapDuration: CFAbsoluteTime = 120

    public var runtimeWorkloadFrameRateCap: Int? {
        runtimeWorkloadSafetyEffectiveFrameRateCap()
    }

    public var runtimeWorkloadFallbackReason: String? {
        runtimeWorkloadSafetyLastFallbackReason
    }

    public var runtimeMemoryPressureCount: Int {
        runtimeWorkloadSafetyMemoryPressureCount
    }

    public var runtimeMemoryPressureLastAgeSeconds: Double? {
        runtimeWorkloadSafetyLastMemoryPressureTime.map {
            max(0, CFAbsoluteTimeGetCurrent() - $0)
        }
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
            .max() ?? preferredScreenMaxRefreshRate()
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
            await self.applyRuntimeWorkloadSafetyCap(
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
                reason: reason,
                appliedAt: now,
                expiresAt: now + Self.runtimeWorkloadSafetyFrameRateCapDuration
            )
            runtimeWorkloadSafetyLastFallbackReason = reason.rawValue
            let currentFrameRate = runtimeWorkloadSafetyCurrentFrameRate(for: streamID)
            guard currentFrameRate > effectiveCap ||
                (refreshRateOverridesByStream[streamID] ?? 0) > effectiveCap ||
                (observedFrameRateByStream[streamID] ?? 0) > effectiveCap
            else {
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

    func runtimeWorkloadSafetyEffectiveFrameRateCap() -> Int? {
        pruneExpiredRuntimeWorkloadSafetyCaps()
        return runtimeWorkloadSafetyFrameRateCapsByStream.values.map(\.frameRate).min()
    }

    private func pruneExpiredRuntimeWorkloadSafetyCaps(now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) {
        runtimeWorkloadSafetyFrameRateCapsByStream = runtimeWorkloadSafetyFrameRateCapsByStream.filter { _, cap in
            cap.expiresAt > now
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
        return preferredScreenMaxRefreshRate()
    }

    func runtimeWorkloadSafetyTransportIsClean(for streamID: StreamID) -> Bool {
        guard let snapshot = metricsStore.snapshot(for: streamID), snapshot.hasHostMetrics else { return false }
        let assessment = MirageTransportPressure.assess(
            sample: MirageTransportPressureSample(
                queueBytes: max(0, snapshot.hostTransportSendQueueBytes ?? 0),
                queueStressBytes: 800_000,
                queueSevereBytes: 2_000_000,
                packetPacerAverageSleepMs: max(0, snapshot.hostTransportPacketPacerAverageSleepMs ?? 0),
                packetPacerStressThresholdMs: 0.75,
                packetPacerSevereThresholdMs: 2.0,
                sendStartDelayAverageMs: max(0, snapshot.hostTransportSendStartDelayAverageMs ?? 0),
                sendStartDelayStressThresholdMs: 2.0,
                sendStartDelaySevereThresholdMs: 6.0,
                sendCompletionAverageMs: max(0, snapshot.hostTransportSendCompletionAverageMs ?? 0),
                sendCompletionStressThresholdMs: 12.0,
                sendCompletionSevereThresholdMs: 28.0,
                transportDropCount: snapshot.hostTransportStalePacketDrops ?? 0,
                transportDropSevereCount: 12
            )
        )
        return !assessment.isStress && !assessment.isDelayOnlyBurst
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

        let frameBudgetMs = 1_000.0 / targetFPS
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
