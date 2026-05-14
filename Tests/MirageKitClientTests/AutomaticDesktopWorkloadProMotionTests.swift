//
//  AutomaticDesktopWorkloadProMotionTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

@testable import MirageKitClient
import CoreGraphics
import Foundation
import Testing

#if os(macOS)
extension AutomaticDesktopWorkloadControllerTests {
    @Test("Clean variable ProMotion cadence above floor does not reconfigure")
    func cleanVariableProMotionCadenceAboveFloorDoesNotReconfigure() {
        var controller = MirageAutomaticDesktopWorkloadController()
        let snapshot = pipelineBoundSnapshot(
            width: 2752,
            height: 2064,
            targetFrameRate: 120,
            cadenceFPS: 78
        )

        let action = advanceThroughPipelinePressure(
            controller: &controller,
            snapshot: snapshot,
            minimumTargetFrameRate: 60,
            maximumTargetFrameRate: 120,
            minimumHealthyFrameRate: 60
        )

        #expect(action == .none)
    }

    @Test("ProMotion transport pressure lowers refresh at the same resolution")
    func proMotionTransportPressureLowersRefreshAtSameResolution() {
        var controller = MirageAutomaticDesktopWorkloadController()
        var snapshot = pipelineBoundSnapshot(
            width: 2752,
            height: 2064,
            targetFrameRate: 120,
            cadenceFPS: 118
        )
        snapshot.hostSendQueueBytes = 2_000_000

        let action = advanceThroughPipelinePressure(
            controller: &controller,
            snapshot: snapshot,
            minimumTargetFrameRate: 60,
            maximumTargetFrameRate: 120
        )

        guard case .reconfigure(let target, _) = action else {
            Issue.record("Expected workload reconfiguration")
            return
        }
        #expect(target.encodedPixelSize == CGSize(width: 2752, height: 2064))
        #expect(target.targetFrameRate == 90)
    }

    @Test("ProMotion presentation collapse does not reconfigure workload")
    func proMotionPresentationCollapseDoesNotReconfigureWorkload() {
        var controller = MirageAutomaticDesktopWorkloadController()
        var snapshot = pipelineBoundSnapshot(
            width: 2752,
            height: 2064,
            targetFrameRate: 120,
            cadenceFPS: 118
        )
        snapshot.submittedFPS = 70
        snapshot.uniqueSubmittedFPS = 70
        snapshot.clientOverwrittenPendingFrames = 8
        snapshot.clientDisplayLayerNotReadyCount = 4
        snapshot.clientPendingFrameAgeMs = 42

        let action = advanceThroughPipelinePressure(
            controller: &controller,
            snapshot: snapshot,
            minimumTargetFrameRate: 60,
            maximumTargetFrameRate: 120
        )

        #expect(action == .none)
    }

    @Test("Severe ProMotion presentation collapse does not downshift")
    func severeProMotionPresentationCollapseDoesNotDownshift() {
        var controller = MirageAutomaticDesktopWorkloadController()
        var snapshot = pipelineBoundSnapshot(
            width: 2752,
            height: 2064,
            targetFrameRate: 120,
            cadenceFPS: 118
        )
        snapshot.submittedFPS = 62
        snapshot.uniqueSubmittedFPS = 62
        snapshot.clientPresentedFPS = 62
        snapshot.clientLayerAcceptedFPS = 62
        snapshot.clientOverwrittenPendingFrames = 5
        snapshot.clientDisplayLayerNotReadyCount = 3
        snapshot.clientPendingFrameAgeMs = 48

        var action: MirageAutomaticDesktopWorkloadController.Action = .none
        for sample in 0..<3 {
            action = controller.advance(
                snapshot: snapshot,
                resizeCriticalSectionActive: false,
                minimumTargetFrameRate: 60,
                maximumTargetFrameRate: 120,
                now: CFAbsoluteTime(sample)
            )
        }

        #expect(action == .none)
    }

    @Test("Virtual-display source-bound ProMotion samples do not reconfigure workload")
    func virtualDisplaySourceBoundProMotionSamplesDoNotReconfigureWorkload() {
        var controller = MirageAutomaticDesktopWorkloadController()
        var snapshot = pipelineBoundSnapshot(
            width: 2752,
            height: 2064,
            targetFrameRate: 120,
            cadenceFPS: 70
        )
        snapshot.hostCaptureUsesDisplayRefreshCadence = true
        snapshot.hostCaptureVirtualDisplayTimingSuspect = true

        var action: MirageAutomaticDesktopWorkloadController.Action = .none
        for sample in 0..<8 {
            action = controller.advance(
                snapshot: snapshot,
                resizeCriticalSectionActive: false,
                minimumTargetFrameRate: 60,
                maximumTargetFrameRate: 120,
                now: CFAbsoluteTime(sample)
            )
        }

        #expect(action == .none)
    }

    @Test("ProMotion severe presentation collapse does not reconfigure workload")
    func proMotionSeverePresentationCollapseDoesNotReconfigureWorkload() {
        var controller = MirageAutomaticDesktopWorkloadController()
        var snapshot = pipelineBoundSnapshot(
            width: 2752,
            height: 2064,
            targetFrameRate: 120,
            cadenceFPS: 118
        )
        snapshot.submittedFPS = 50
        snapshot.uniqueSubmittedFPS = 50
        snapshot.clientOverwrittenPendingFrames = 8
        snapshot.clientDisplayLayerNotReadyCount = 4
        snapshot.clientPendingFrameAgeMs = 42

        let action = advanceThroughPipelinePressure(
            controller: &controller,
            snapshot: snapshot,
            minimumTargetFrameRate: 60,
            maximumTargetFrameRate: 120
        )

        #expect(action == .none)
    }

    @Test("ProMotion client failure below floor does not reconfigure workload")
    func proMotionClientFailureBelowFloorDoesNotReconfigureWorkload() {
        var controller = MirageAutomaticDesktopWorkloadController()
        var snapshot = pipelineBoundSnapshot(
            width: 2752,
            height: 2064,
            targetFrameRate: 120,
            cadenceFPS: 118
        )
        snapshot.submittedFPS = 50
        snapshot.uniqueSubmittedFPS = 50
        snapshot.clientPresentedFPS = 50
        snapshot.clientLayerAcceptedFPS = 50
        snapshot.clientOverwrittenPendingFrames = 4
        snapshot.clientDisplayLayerNotReadyCount = 2
        snapshot.clientPendingFrameAgeMs = 48

        let action = advanceThroughPipelinePressure(
            controller: &controller,
            snapshot: snapshot,
            minimumTargetFrameRate: 60,
            maximumTargetFrameRate: 120,
            minimumHealthyFrameRate: 60
        )

        #expect(action == .none)
    }

    @Test("Sustained clean ProMotion custom tier promotes refresh at the same resolution")
    func sustainedCleanProMotionCustomTierPromotesRefreshAtSameResolution() {
        var controller = MirageAutomaticDesktopWorkloadController()
        let snapshot = pipelineBoundSnapshot(
            width: 2752,
            height: 2064,
            targetFrameRate: 60,
            cadenceFPS: 60
        )

        var action: MirageAutomaticDesktopWorkloadController.Action = .none
        for sample in 0..<12 {
            let sampleAction = controller.advance(
                snapshot: snapshot,
                resizeCriticalSectionActive: false,
                minimumTargetFrameRate: 60,
                maximumTargetFrameRate: 120,
                now: CFAbsoluteTime(sample)
            )
            if sampleAction != .none {
                action = sampleAction
            }
        }

        guard case .reconfigure(let target, _) = action else {
            Issue.record("Expected workload promotion")
            return
        }
        #expect(target.encodedPixelSize == CGSize(width: 2752, height: 2064))
        #expect(target.targetFrameRate == 90)
    }
}
#endif
