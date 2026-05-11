//
//  MirageClientService+RuntimeWorkloadSafety.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/7/26.
//
//  Runtime workload safety policy for client memory pressure.
//

import Foundation
import MirageKit

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
    }

    nonisolated static let runtimeWorkloadSafetyMinimumFrameRate = 30
    nonisolated static let runtimeWorkloadSafetyMemoryPressureRepeatWindow: CFAbsoluteTime = 600
    nonisolated static let runtimeWorkloadSafetyStallTelemetryWindow: CFAbsoluteTime = 300
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
        guard Self.runtimeWorkloadSafetyStallEventReportsAdaptivePressure(event) else { return }

        let now = CFAbsoluteTimeGetCurrent()
        let recentStalls = (runtimeWorkloadSafetyStallTimesByStream[streamID] ?? [])
            .filter { now - $0 <= Self.runtimeWorkloadSafetyStallTelemetryWindow } + [now]
        runtimeWorkloadSafetyStallTimesByStream[streamID] = recentStalls

        MirageLogger.client(
            "Runtime workload pressure noted for stream \(streamID): event=\(event) " +
                "recent=\(recentStalls.count); adaptive streaming controller owns ProMotion relief"
        )
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

    nonisolated static func runtimeWorkloadSafetyStallEventReportsAdaptivePressure(
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

}
