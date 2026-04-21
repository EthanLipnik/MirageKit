//
//  AutomaticDesktopWorkloadControllerTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/21/26.
//

@testable import MirageKitClient
import Foundation
import Testing

#if os(macOS)
@Suite("Automatic Desktop Workload Controller")
struct AutomaticDesktopWorkloadControllerTests {
    @Test("Sustained 4K60 pipeline pressure drops to 4K30")
    func sustainedFourK60PipelinePressureDropsToFourK30() {
        var controller = MirageAutomaticDesktopWorkloadController()
        let snapshot = pipelineBoundSnapshot(
            width: 3840,
            height: 2160,
            targetFrameRate: 60,
            cadenceFPS: 45
        )

        #expect(controller.advance(snapshot: snapshot, resizeCriticalSectionActive: false, now: 0) == .none)
        #expect(controller.advance(snapshot: snapshot, resizeCriticalSectionActive: false, now: 1) == .none)
        let action = controller.advance(snapshot: snapshot, resizeCriticalSectionActive: false, now: 2)

        guard case .reconfigure(let target, _) = action else {
            Issue.record("Expected workload reconfiguration")
            return
        }
        #expect(target == .fourK30)
    }

    @Test("Sustained 4K30 pipeline pressure drops resolution")
    func sustainedFourK30PipelinePressureDropsResolution() {
        var controller = MirageAutomaticDesktopWorkloadController()
        let snapshot = pipelineBoundSnapshot(
            width: 3840,
            height: 2160,
            targetFrameRate: 30,
            cadenceFPS: 20
        )

        _ = controller.advance(snapshot: snapshot, resizeCriticalSectionActive: false, now: 0)
        _ = controller.advance(snapshot: snapshot, resizeCriticalSectionActive: false, now: 1)
        let action = controller.advance(snapshot: snapshot, resizeCriticalSectionActive: false, now: 2)

        guard case .reconfigure(let target, _) = action else {
            Issue.record("Expected workload reconfiguration")
            return
        }
        #expect(target == .qhd30)
    }

    @Test("Dirty transport suppresses workload changes")
    func dirtyTransportSuppressesWorkloadChanges() {
        var controller = MirageAutomaticDesktopWorkloadController()
        var snapshot = pipelineBoundSnapshot(
            width: 3840,
            height: 2160,
            targetFrameRate: 60,
            cadenceFPS: 45
        )
        snapshot.hostSendQueueBytes = 2_000_000

        _ = controller.advance(snapshot: snapshot, resizeCriticalSectionActive: false, now: 0)
        _ = controller.advance(snapshot: snapshot, resizeCriticalSectionActive: false, now: 1)
        let action = controller.advance(snapshot: snapshot, resizeCriticalSectionActive: false, now: 2)

        #expect(action == .none)
    }

    @Test("Resize critical sections suppress workload changes")
    func resizeCriticalSectionsSuppressWorkloadChanges() {
        var controller = MirageAutomaticDesktopWorkloadController()
        let snapshot = pipelineBoundSnapshot(
            width: 3840,
            height: 2160,
            targetFrameRate: 60,
            cadenceFPS: 45
        )

        _ = controller.advance(snapshot: snapshot, resizeCriticalSectionActive: true, now: 0)
        _ = controller.advance(snapshot: snapshot, resizeCriticalSectionActive: true, now: 1)
        let action = controller.advance(snapshot: snapshot, resizeCriticalSectionActive: true, now: 2)

        #expect(action == .none)
    }

    @Test("Workload reconfiguration has a 20 second cooldown")
    func workloadReconfigurationHasCooldown() {
        var controller = MirageAutomaticDesktopWorkloadController()
        let snapshot = pipelineBoundSnapshot(
            width: 3840,
            height: 2160,
            targetFrameRate: 60,
            cadenceFPS: 45
        )

        _ = controller.advance(snapshot: snapshot, resizeCriticalSectionActive: false, now: 0)
        _ = controller.advance(snapshot: snapshot, resizeCriticalSectionActive: false, now: 1)
        let firstAction = controller.advance(snapshot: snapshot, resizeCriticalSectionActive: false, now: 2)
        #expect(firstAction != .none)

        _ = controller.advance(snapshot: snapshot, resizeCriticalSectionActive: false, now: 3)
        _ = controller.advance(snapshot: snapshot, resizeCriticalSectionActive: false, now: 4)
        let cooldownAction = controller.advance(snapshot: snapshot, resizeCriticalSectionActive: false, now: 5)
        #expect(cooldownAction == .none)

        let afterCooldownAction = controller.advance(snapshot: snapshot, resizeCriticalSectionActive: false, now: 23)
        #expect(afterCooldownAction != .none)
    }

    private func pipelineBoundSnapshot(
        width: Int,
        height: Int,
        targetFrameRate: Int,
        cadenceFPS: Double
    ) -> MirageClientMetricsSnapshot {
        var snapshot = MirageClientMetricsSnapshot(
            decodedFPS: cadenceFPS,
            receivedFPS: cadenceFPS,
            submittedFPS: cadenceFPS,
            uniqueSubmittedFPS: cadenceFPS,
            decodeHealthy: true,
            hostEncodedFPS: cadenceFPS,
            hostActiveQuality: 0.70,
            hostTargetFrameRate: targetFrameRate,
            hostFrameBudgetMs: 1000.0 / Double(targetFrameRate),
            hostAverageEncodeMs: 10,
            hostCaptureIngressFPS: cadenceFPS,
            hostCaptureFPS: cadenceFPS,
            hostEncodeAttemptFPS: cadenceFPS,
            hostEncodedWidth: width,
            hostEncodedHeight: height,
            hasHostMetrics: true
        )
        snapshot.hostSendQueueBytes = 0
        snapshot.hostSendStartDelayAverageMs = 0
        snapshot.hostSendCompletionAverageMs = 0
        snapshot.hostPacketPacerAverageSleepMs = 0
        snapshot.hostStalePacketDrops = 0
        return snapshot
    }
}
#endif
