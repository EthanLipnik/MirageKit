//
//  RuntimeWorkloadSafetyTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/7/26.
//
//  Runtime workload safety coverage.
//

import CoreGraphics
import Foundation
@testable import MirageKit
@testable import MirageKitClient
import Testing

#if os(macOS)
@Suite("Runtime Workload Safety")
struct RuntimeWorkloadSafetyTests {
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

    @Test("Runtime workload safety restores 30fps caps to 60fps")
    func memoryPressureRestoreTargets() {
        #expect(MirageClientService.runtimeWorkloadSafetyRestoreFrameRate(
            currentFrameRate: 120,
            cap: 60
        ) == nil)
        #expect(MirageClientService.runtimeWorkloadSafetyRestoreFrameRate(
            currentFrameRate: 90,
            cap: 60
        ) == nil)
        #expect(MirageClientService.runtimeWorkloadSafetyRestoreFrameRate(
            currentFrameRate: 120,
            cap: 30
        ) == 60)
        #expect(MirageClientService.runtimeWorkloadSafetyRestoreFrameRate(
            currentFrameRate: 60,
            cap: 30
        ) == 60)
        #expect(MirageClientService.runtimeWorkloadSafetyRestoreFrameRate(
            currentFrameRate: 30,
            cap: 30
        ) == nil)
    }

    @Test("Presentation and recovery stalls never allow host FPS fallback")
    func recoveryEventsDoNotAllowFrameRateFallback() {
        #expect(!MirageClientService.runtimeWorkloadSafetyStallEventAllowsFrameRateFallback(.presentationRecovery))
        #expect(!MirageClientService.runtimeWorkloadSafetyStallEventAllowsFrameRateFallback(.keyframeStarved))
        #expect(!MirageClientService.runtimeWorkloadSafetyStallEventAllowsFrameRateFallback(.packetStarved))
        #expect(!MirageClientService.runtimeWorkloadSafetyStallEventAllowsFrameRateFallback(.clientRenderCapacity))
    }

    @Test("Runtime caps clamp frame rates without forcing streams below their current target")
    func cappedFrameRate() {
        #expect(MirageClientService.runtimeWorkloadSafetyCappedFrameRate(120, cap: 60) == 60)
        #expect(MirageClientService.runtimeWorkloadSafetyCappedFrameRate(90, cap: 60) == 60)
        #expect(MirageClientService.runtimeWorkloadSafetyCappedFrameRate(60, cap: 30) == 30)
        #expect(MirageClientService.runtimeWorkloadSafetyCappedFrameRate(30, cap: 60) == 30)
        #expect(MirageClientService.runtimeWorkloadSafetyCappedFrameRate(20, cap: 30) == 20)
        #expect(MirageClientService.runtimeWorkloadSafetyCappedFrameRate(120, cap: nil) == 120)
    }

    @Test("Runtime workload scale downshift uses session tiers")
    func runtimeWorkloadScaleDownshiftTargets() {
        #expect(MirageClientService.runtimeWorkloadSafetyNextScaleDownshift(currentScale: 1.0) == 0.75)
        #expect(MirageClientService.runtimeWorkloadSafetyNextScaleDownshift(currentScale: 0.76) == 0.75)
        #expect(MirageClientService.runtimeWorkloadSafetyNextScaleDownshift(currentScale: 0.75) == 0.5)
        #expect(MirageClientService.runtimeWorkloadSafetyNextScaleDownshift(currentScale: 0.51) == 0.5)
        #expect(MirageClientService.runtimeWorkloadSafetyNextScaleDownshift(currentScale: 0.5) == nil)
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
            expiresAt: CFAbsoluteTimeGetCurrent() + 60
        )

        #expect(service.maxRefreshRateOverride == 120)
        #expect(service.screenMaxRefreshRate == 120)
        #expect(service.resolvedStreamCadenceFrameRate(for: streamID, fallback: 120) == 60)
        #expect(service.resolvedStreamCadenceFrameRate(for: 8, fallback: 120) == 120)

        service.resetRuntimeWorkloadSafetyState()

        #expect(service.maxRefreshRateOverride == 120)
        #expect(service.screenMaxRefreshRate == 120)
        #expect(service.resolvedStreamCadenceFrameRate(for: streamID, fallback: 120) == 120)
    }

    @MainActor
    @Test("Runtime workload cap stores the 60fps restore target")
    func runtimeCapStoresRestoreFrameRateTarget() async throws {
        let pair = try await makeLoopbackControlPair()
        try await pair.startAuthenticatedSessions()

        let serverControlTask = Task {
            try await MirageControlChannel.accept(from: pair.server)
        }
        let clientControl = try await MirageControlChannel.open(on: pair.client)
        let serverControl = try await serverControlTask.value
        let serverReceiver = ControlMessageReceiver(channel: serverControl)

        do {
            let service = MirageClientService(deviceName: "Loopback Client")
            let streamID: StreamID = 7
            service.loomSession = pair.client
            service.controlChannel = clientControl
            service.connectionState = .connected(host: "Loopback Host")
            service.desktopStreamID = streamID
            service.refreshRateOverridesByStream[streamID] = 60

            await service.applyRuntimeWorkloadSafetyCap(
                targetFrameRate: 30,
                reason: .memoryPressure,
                triggerStreamID: streamID
            )

            let capRequestEnvelope = try await serverReceiver.next()
            #expect(capRequestEnvelope.type == .streamEncoderSettingsChange)
            let capRequest = try capRequestEnvelope.decode(StreamEncoderSettingsChangeMessage.self)
            #expect(capRequest.streamID == streamID)
            #expect(capRequest.targetFrameRate == 30)
            #expect(service.runtimeWorkloadSafetyRestoreFrameRatesByStream[streamID] == 60)

            service.resetRuntimeWorkloadSafetyState()
        } catch {
            await clientControl.cancel()
            await serverControl.cancel()
            await pair.stop()
            throw error
        }

        await clientControl.cancel()
        await serverControl.cancel()
        await pair.stop()
    }

    @MainActor
    @Test("Expired runtime workload cap restores the 60fps target")
    func expiredRuntimeCapRestoresFrameRateTarget() async throws {
        let pair = try await makeLoopbackControlPair()
        try await pair.startAuthenticatedSessions()

        let serverControlTask = Task {
            try await MirageControlChannel.accept(from: pair.server)
        }
        let clientControl = try await MirageControlChannel.open(on: pair.client)
        let serverControl = try await serverControlTask.value
        let serverReceiver = ControlMessageReceiver(channel: serverControl)

        do {
            let service = MirageClientService(deviceName: "Loopback Client")
            let streamID: StreamID = 9
            let expiresAt = CFAbsoluteTimeGetCurrent() - 1
            service.loomSession = pair.client
            service.controlChannel = clientControl
            service.connectionState = .connected(host: "Loopback Host")
            service.desktopStreamID = streamID
            service.refreshRateOverridesByStream[streamID] = 30
            service.runtimeWorkloadSafetyFrameRateCapsByStream[streamID] = RuntimeWorkloadSafetyFrameRateCap(
                frameRate: 30,
                expiresAt: expiresAt
            )
            service.runtimeWorkloadSafetyRestoreFrameRatesByStream[streamID] = 60
            service.runtimeWorkloadSafetyLastFallbackReason = "memory_pressure"
            #expect(service.runtimeWorkloadSafetyFrameRateCap(for: streamID) == nil)
            #expect(service.runtimeWorkloadSafetyFrameRateCapsByStream[streamID] == nil)

            await service.restoreExpiredRuntimeWorkloadSafetyFrameRateIfNeeded(
                for: streamID,
                expectedExpiresAt: expiresAt
            )

            let restoreRequestEnvelope = try await serverReceiver.next()
            #expect(restoreRequestEnvelope.type == .streamEncoderSettingsChange)
            let restoreRequest = try restoreRequestEnvelope.decode(StreamEncoderSettingsChangeMessage.self)
            #expect(restoreRequest.streamID == streamID)
            #expect(restoreRequest.targetFrameRate == 60)
            #expect(service.runtimeWorkloadSafetyFrameRateCapsByStream[streamID] == nil)
            #expect(service.runtimeWorkloadSafetyRestoreFrameRatesByStream[streamID] == nil)
            #expect(service.runtimeWorkloadSafetyLastFallbackReason == nil)
            #expect(service.refreshRateOverridesByStream[streamID] == 60)
        } catch {
            await clientControl.cancel()
            await serverControl.cancel()
            await pair.stop()
            throw error
        }

        await clientControl.cancel()
        await serverControl.cancel()
        await pair.stop()
    }
}
#endif
