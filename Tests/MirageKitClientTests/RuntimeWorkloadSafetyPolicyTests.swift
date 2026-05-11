//
//  RuntimeWorkloadSafetyPolicyTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/7/26.
//
//  Runtime workload safety policy coverage.
//

import CoreGraphics
import Foundation
@testable import MirageKitClient
import Testing

#if os(macOS)
@Suite("Runtime Workload Safety Policy")
struct RuntimeWorkloadSafetyPolicyTests {
    @Test("Memory pressure caps ProMotion streams before repeated pressure escalates")
    func memoryPressureTargets() {
        #expect(MirageClientService.runtimeWorkloadSafetyMemoryPressureTarget(
            currentFrameRate: 120,
            repeated: false
        ) == 60)
        #expect(MirageClientService.runtimeWorkloadSafetyMemoryPressureTarget(
            currentFrameRate: 90,
            repeated: false
        ) == 60)
        #expect(MirageClientService.runtimeWorkloadSafetyMemoryPressureTarget(
            currentFrameRate: 60,
            repeated: false
        ) == 30)
        #expect(MirageClientService.runtimeWorkloadSafetyMemoryPressureTarget(
            currentFrameRate: 31,
            repeated: false
        ) == 30)
        #expect(MirageClientService.runtimeWorkloadSafetyMemoryPressureTarget(
            currentFrameRate: 30,
            repeated: false
        ) == nil)
        #expect(MirageClientService.runtimeWorkloadSafetyMemoryPressureTarget(
            currentFrameRate: 20,
            repeated: false
        ) == nil)

        #expect(MirageClientService.runtimeWorkloadSafetyMemoryPressureTarget(
            currentFrameRate: 60,
            repeated: true
        ) == 30)
        #expect(MirageClientService.runtimeWorkloadSafetyMemoryPressureTarget(
            currentFrameRate: 30,
            repeated: true
        ) == nil)
    }

    @Test("Runtime stall events are telemetry for the adaptive controller, not frame-rate caps")
    func recoveryEventsOnlyReportAdaptivePressure() {
        #expect(MirageClientService.runtimeWorkloadSafetyStallEventReportsAdaptivePressure(.presentationRecovery))
        #expect(!MirageClientService.runtimeWorkloadSafetyStallEventReportsAdaptivePressure(.keyframeStarved))
        #expect(!MirageClientService.runtimeWorkloadSafetyStallEventReportsAdaptivePressure(.packetStarved))
        #expect(MirageClientService.runtimeWorkloadSafetyStallEventReportsAdaptivePressure(.clientRenderCapacity))
    }

    @Test("Runtime caps clamp frame rates without forcing streams below their current target")
    func cappedFrameRatePolicy() {
        #expect(MirageClientService.runtimeWorkloadSafetyCappedFrameRate(120, cap: 60) == 60)
        #expect(MirageClientService.runtimeWorkloadSafetyCappedFrameRate(90, cap: 60) == 60)
        #expect(MirageClientService.runtimeWorkloadSafetyCappedFrameRate(60, cap: 30) == 30)
        #expect(MirageClientService.runtimeWorkloadSafetyCappedFrameRate(30, cap: 60) == 30)
        #expect(MirageClientService.runtimeWorkloadSafetyCappedFrameRate(20, cap: 30) == 20)
        #expect(MirageClientService.runtimeWorkloadSafetyCappedFrameRate(120, cap: nil) == 120)
    }

    @Test("Automatic desktop workload tiers cannot promote above the runtime cap")
    func automaticDesktopWorkloadTierIsCapped() {
        let target = MirageAutomaticDesktopWorkloadTier(
            encodedPixelSize: CGSize(width: 3840, height: 2160),
            targetFrameRate: 120
        )
        let capped = MirageClientService.runtimeWorkloadSafetyCappedTier(target, cap: 60)

        #expect(capped.encodedPixelSize == target.encodedPixelSize)
        #expect(capped.targetFrameRate == 60)
    }

    @MainActor
    @Test("Runtime cap is stream scoped and does not mutate saved frame-rate preference")
    func runtimeCapIsStreamScopedAndDoesNotPersist() {
        let service = MirageClientService()
        let streamID: StreamID = 7
        service.updateMaxRefreshRateOverride(120)
        service.runtimeWorkloadSafetyFrameRateCapsByStream[streamID] = RuntimeWorkloadSafetyFrameRateCap(
            frameRate: 60,
            reason: .memoryPressure,
            appliedAt: CFAbsoluteTimeGetCurrent(),
            expiresAt: CFAbsoluteTimeGetCurrent() + 60
        )

        #expect(service.maxRefreshRateOverride == 120)
        #expect(service.getScreenMaxRefreshRate() == 120)
        #expect(service.resolvedStreamCadenceFrameRate(for: streamID, fallback: 120) == 60)
        #expect(service.resolvedStreamCadenceFrameRate(for: 8, fallback: 120) == 120)

        service.resetRuntimeWorkloadSafetyState()

        #expect(service.maxRefreshRateOverride == 120)
        #expect(service.getScreenMaxRefreshRate() == 120)
        #expect(service.resolvedStreamCadenceFrameRate(for: streamID, fallback: 120) == 120)
    }
}
#endif
