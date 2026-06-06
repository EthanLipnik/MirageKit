//
//  ReceiverHealthControllerTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/31/26.
//

@testable import MirageKitClient
import Foundation
import MirageKit
import Testing
import MirageDiagnostics

#if os(macOS)
@Suite("Receiver Health Controller")
struct ReceiverHealthControllerTests {
    @Test("Severe transport pressure backs off after consecutive samples")
    func severeTransportPressureBacksOffAfterConsecutiveSamples() {
        var controller = MirageReceiverHealthController()
        let snapshot = severeTransportSnapshot()

        let firstAction = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 50_000_000,
            now: 10
        )
        let secondAction = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 50_000_000,
            now: 12
        )

        #expect(firstAction == .none)
        #expect(secondAction == .backoff(targetBitrateBps: 17_000_000))
        #expect(controller.state == .backingOff)
    }

    @Test("Delay-only sender pressure suppresses probes without backoff")
    func delayOnlySenderPressureSuppressesProbesWithoutBackoff() {
        var controller = MirageReceiverHealthController()
        let delayedSnapshot = delayOnlySnapshot()
        let healthySnapshot = healthySnapshot(activeQuality: 0.62)

        for time in [0.0, 2.0, 4.0] {
            let action = controller.advance(
                snapshots: [delayedSnapshot],
                currentBitrateBps: 20_000_000,
                ceilingBps: 300_000_000,
                now: time
            )
            #expect(action == .none)
        }
        let firstCleanAction = controller.advance(
            snapshots: [healthySnapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 300_000_000,
            now: 6
        )
        let suppressedProbeAction = controller.advance(
            snapshots: [healthySnapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 300_000_000,
            now: 6.5
        )
        let resumedProbeAction = controller.advance(
            snapshots: [healthySnapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 300_000_000,
            now: 7.1
        )

        #expect(firstCleanAction == .none)
        #expect(suppressedProbeAction == .none)
        #expect(resumedProbeAction == .probe(targetBitrateBps: 32_000_000))
        #expect(controller.state == .stable)
    }

    @Test("Startup queue spikes suppress backoff without transport loss")
    func startupQueueSpikesSuppressBackoffWithoutTransportLoss() {
        var controller = MirageReceiverHealthController()
        let snapshot = startupQueueSpikeSnapshot()

        for time in [0.0, 2.0, 4.0] {
            let action = controller.advance(
                snapshots: [snapshot],
                currentBitrateBps: 20_000_000,
                ceilingBps: 300_000_000,
                now: time
            )
            #expect(action == .none)
        }

        #expect(controller.state == .stable)
        #expect(controller.lastTransportPressureReason != nil)
    }

    @Test("Healthy fast-start windows probe upward after two clean samples")
    func healthyFastStartWindowsProbeUpwardAfterTwoCleanSamples() {
        var controller = MirageReceiverHealthController()
        let snapshot = healthySnapshot(activeQuality: 0.62)

        let firstAction = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 300_000_000,
            now: 0
        )
        let secondAction = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 300_000_000,
            now: 2
        )

        #expect(firstAction == .none)
        #expect(secondAction == .probe(targetBitrateBps: 32_000_000))
        #expect(controller.state == .stable)
    }

    @Test("Conservative proximity mode delays and shrinks bitrate probes")
    func conservativeProximityModeDelaysAndShrinksBitrateProbes() {
        var controller = MirageReceiverHealthController(
            promotionRecoveryMode: .conservativeProximity
        )
        let snapshot = healthySnapshot(activeQuality: 0.62)
        var action: MirageReceiverHealthController.Action = .none

        for sampleIndex in 0 ..< 29 {
            action = controller.advance(
                snapshots: [snapshot],
                currentBitrateBps: 60_000_000,
                ceilingBps: 128_000_000,
                now: Double(sampleIndex * 2)
            )
            #expect(action == .none)
        }

        action = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 60_000_000,
            ceilingBps: 128_000_000,
            now: 58
        )

        #expect(action == .probe(targetBitrateBps: 66_000_000))
    }

    @Test("Recent interaction defers probes while allowing severe backoff")
    func recentInteractionDefersProbesWhileAllowingSevereBackoff() {
        var controller = MirageReceiverHealthController()
        let healthySnapshot = healthySnapshot(activeQuality: 0.62)
        let stressedSnapshot = severeTransportSnapshot()

        _ = controller.advance(
            snapshots: [healthySnapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 80_000_000,
            now: 0,
            allowsNewProbe: false
        )
        let deferredProbe = controller.advance(
            snapshots: [healthySnapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 80_000_000,
            now: 2,
            allowsNewProbe: false
        )
        let firstStressAction = controller.advance(
            snapshots: [stressedSnapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 80_000_000,
            now: 4,
            allowsNewProbe: false
        )
        let secondStressAction = controller.advance(
            snapshots: [stressedSnapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 80_000_000,
            now: 6,
            allowsNewProbe: false
        )

        #expect(deferredProbe == .none)
        #expect(firstStressAction == .none)
        #expect(secondStressAction == .backoff(targetBitrateBps: 17_000_000))
    }

    @Test("Pending probe rolls back only on transport pressure")
    func pendingProbeRollsBackOnlyOnTransportPressure() {
        var controller = MirageReceiverHealthController()
        let healthySnapshot = healthySnapshot(activeQuality: 0.62)
        let stressedSnapshot = severeTransportSnapshot()

        _ = controller.advance(
            snapshots: [healthySnapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 300_000_000,
            now: 0
        )
        let probe = controller.advance(
            snapshots: [healthySnapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 300_000_000,
            now: 2
        )
        let rollback = controller.advance(
            snapshots: [stressedSnapshot],
            currentBitrateBps: 32_000_000,
            ceilingBps: 300_000_000,
            now: 4
        )

        #expect(probe == .probe(targetBitrateBps: 32_000_000))
        #expect(rollback == .backoff(targetBitrateBps: 20_000_000))
    }

    @Test("Pending probe ignores decode stalls without unsafe ceiling")
    func pendingProbeIgnoresDecodeStallsWithoutUnsafeCeiling() {
        var controller = MirageReceiverHealthController()
        let healthySnapshot = healthySnapshot(activeQuality: 0.62)
        let decodeStalledSnapshot = decodeStalledButTransportHealthySnapshot()

        _ = controller.advance(
            snapshots: [healthySnapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 300_000_000,
            now: 0
        )
        let probe = controller.advance(
            snapshots: [healthySnapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 300_000_000,
            now: 2
        )
        let decodeAction = controller.advance(
            snapshots: [decodeStalledSnapshot],
            currentBitrateBps: 32_000_000,
            ceilingBps: 300_000_000,
            now: 4
        )

        #expect(probe == .probe(targetBitrateBps: 32_000_000))
        #expect(decodeAction == .none)
        #expect(controller.state == .stable)
    }

    @Test("Presentation-bound samples do not block transport probing")
    func presentationBoundSamplesDoNotBlockTransportProbing() {
        var controller = MirageReceiverHealthController()
        let snapshot = presentationBoundButTransportHealthySnapshot()

        _ = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 300_000_000,
            now: 0
        )
        let secondAction = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 300_000_000,
            now: 2
        )

        #expect(secondAction == .probe(targetBitrateBps: 32_000_000))
        #expect(controller.state == .stable)
    }

    @Test("Host cadence limits do not block clean transport probing")
    func hostCadenceLimitsDoNotBlockCleanTransportProbing() {
        var controller = MirageReceiverHealthController()
        let snapshot = captureBoundButTransportHealthySnapshot()

        _ = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 48_000_000,
            ceilingBps: 136_000_000,
            now: 0
        )
        let action = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 48_000_000,
            ceilingBps: 136_000_000,
            now: 2
        )

        #expect(action == .probe(targetBitrateBps: 60_000_000))
    }

    @Test("Transport drops trigger backoff even when decode metrics look healthy")
    func transportDropsTriggerBackoffEvenWhenDecodeLooksHealthy() {
        var controller = MirageReceiverHealthController()
        var snapshot = healthySnapshot(activeQuality: 0.62)
        snapshot.hostStalePacketDrops = 12

        let firstAction = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 80_000_000,
            now: 10
        )
        let secondAction = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 80_000_000,
            now: 12
        )
        let thirdAction = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 80_000_000,
            now: 14
        )

        #expect(firstAction == .none)
        #expect(secondAction == .none)
        #expect(thirdAction == .backoff(targetBitrateBps: 18_000_000))
        #expect(controller.state == .backingOff)
    }

    @Test("Client fragment loss triggers backoff without host send pressure")
    func clientFragmentLossTriggersBackoffWithoutHostSendPressure() {
        var controller = MirageReceiverHealthController()
        var snapshot = healthySnapshot(activeQuality: 0.62)
        snapshot.clientReassemblerIncompleteFrameTimeouts = 3
        snapshot.clientReassemblerIncompleteFrameNoProgressTimeouts = 3
        snapshot.clientReassemblerMissingFragmentTimeouts = 160

        let firstAction = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 48_000_000,
            ceilingBps: 80_000_000,
            now: 0
        )
        let secondAction = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 40_800_000,
            ceilingBps: 80_000_000,
            now: 2
        )

        #expect(firstAction == .backoff(targetBitrateBps: 40_800_000))
        #expect(secondAction == .none)
        #expect(
            controller.lastTransportPressureReason ==
                "client fragment loss frames=3 noProgress=3 lifetime=0 forwardGaps=0 missing=160"
        )
    }

    @Test("Repeated receiver media delivery failures use stronger temporary backoff")
    func repeatedReceiverMediaDeliveryFailuresUseStrongerTemporaryBackoff() {
        var controller = MirageReceiverHealthController()
        var snapshot = healthySnapshot(activeQuality: 0.62)
        snapshot.clientReassemblerIncompleteFrameTimeouts = 1
        snapshot.clientReassemblerIncompleteFrameNoProgressTimeouts = 1
        snapshot.clientReassemblerMissingFragmentTimeouts = 8

        let firstAction = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 48_000_000,
            ceilingBps: 80_000_000,
            now: 0
        )
        let suppressedSecondFailure = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 40_800_000,
            ceilingBps: 80_000_000,
            now: 5
        )
        let strongerBackoff = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 40_800_000,
            ceilingBps: 80_000_000,
            now: 10.1
        )

        #expect(firstAction == .backoff(targetBitrateBps: 40_800_000))
        #expect(suppressedSecondFailure == .none)
        #expect(strongerBackoff == .backoff(targetBitrateBps: 30_600_000))
    }

    @Test("Conservative proximity media failures back off quickly to floor")
    func conservativeProximityMediaFailuresBackOffQuicklyToFloor() {
        var controller = MirageReceiverHealthController(
            promotionRecoveryMode: .conservativeProximity
        )
        var snapshot = healthySnapshot(activeQuality: 0.62)
        snapshot.clientReassemblerIncompleteFrameTimeouts = 1
        snapshot.clientReassemblerIncompleteFrameNoProgressTimeouts = 1
        snapshot.clientReassemblerMissingFragmentTimeouts = 8

        let firstAction = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 48_000_000,
            ceilingBps: 80_000_000,
            now: 0
        )
        let repeatedAction = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 33_600_000,
            ceilingBps: 80_000_000,
            now: 2.1
        )
        snapshot.clientReassemblerMissingFragmentTimeouts = 160
        let severeRepeatedAction = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 20_160_000,
            ceilingBps: 80_000_000,
            now: 4.2
        )

        #expect(firstAction == .backoff(targetBitrateBps: 33_600_000))
        #expect(repeatedAction == .backoff(targetBitrateBps: 20_160_000))
        #expect(severeRepeatedAction == .backoff(targetBitrateBps: 12_000_000))
    }

    @Test("P-frame latency pressure backs off without transport loss counters")
    func pFrameLatencyPressureBacksOffWithoutTransportLossCounters() {
        var controller = MirageReceiverHealthController()
        var snapshot = healthySnapshot(activeQuality: 0.62)
        snapshot.clientPFrameCompletionLatencyP95Ms = 300

        let firstAction = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 30_000_000,
            ceilingBps: 36_000_000,
            now: 0
        )
        let secondAction = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 30_000_000,
            ceilingBps: 36_000_000,
            now: 2
        )
        let thirdAction = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 30_000_000,
            ceilingBps: 36_000_000,
            now: 4
        )

        #expect(firstAction == .none)
        #expect(secondAction == .none)
        #expect(thirdAction == .backoff(targetBitrateBps: 25_500_000))
        #expect(controller.lastTransportPressureReason == "client p-frame latency p95=300.0ms late=0")
    }

    @Test("Severe P-frame latency uses stronger media backoff floor")
    func severePFrameLatencyUsesStrongerMediaBackoffFloor() {
        var controller = MirageReceiverHealthController()
        var snapshot = healthySnapshot(activeQuality: 0.62)
        snapshot.clientPFrameCompletionLatencyP95Ms = 500

        _ = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 36_000_000,
            ceilingBps: 36_000_000,
            now: 0,
            minimumBitrateFloorBps: 21_600_000
        )
        let action = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 36_000_000,
            ceilingBps: 36_000_000,
            now: 2,
            minimumBitrateFloorBps: 21_600_000
        )

        #expect(action == .backoff(targetBitrateBps: 27_000_000))
    }

    @Test("Delivery collapse behind healthy host cadence backs off")
    func deliveryCollapseBehindHealthyHostCadenceBacksOff() {
        var controller = MirageReceiverHealthController()
        var networkSnapshot = healthySnapshot(activeQuality: 0.62)
        networkSnapshot.hostEncodedFPS = 60
        networkSnapshot.receivedFPS = 8
        networkSnapshot.decodedFPS = 8
        networkSnapshot.submittedFPS = 8
        networkSnapshot.uniqueSubmittedFPS = 8

        _ = controller.advance(
            snapshots: [networkSnapshot],
            currentBitrateBps: 48_000_000,
            ceilingBps: 136_000_000,
            now: 10
        )
        let networkBackoff = controller.advance(
            snapshots: [networkSnapshot],
            currentBitrateBps: 48_000_000,
            ceilingBps: 136_000_000,
            now: 12
        )

        #expect(networkBackoff == .backoff(targetBitrateBps: 40_800_000))
        #expect(
            controller.lastTransportPressureReason ==
                "client delivery cadence host=60.0fps received=8.0fps worstGap=0.0ms p95=0.0ms p99=0.0ms"
        )
    }

    @Test("Automatic transport health ignores cadence-only delivery collapse")
    func automaticTransportHealthIgnoresCadenceOnlyDeliveryCollapse() {
        var controller = MirageReceiverHealthController()
        var snapshot = healthySnapshot(activeQuality: 0.62)
        snapshot.hostEncodedFPS = 60
        snapshot.receivedFPS = 8
        snapshot.decodedFPS = 8
        snapshot.submittedFPS = 8
        snapshot.uniqueSubmittedFPS = 8

        for sampleIndex in 0 ..< 4 {
            let action = controller.advance(
                snapshots: [snapshot],
                currentBitrateBps: 48_000_000,
                ceilingBps: 48_000_000,
                now: 10 + Double(sampleIndex * 2),
                usesCadenceDeliveryPressure: false
            )
            #expect(action == .none)
        }

        #expect(controller.state == .stable)
        #expect(controller.lastTransportPressureReason == nil)
    }

    @Test("Automatic transport health ignores presentation-gap-only cadence")
    func automaticTransportHealthIgnoresPresentationGapOnlyCadence() {
        var controller = MirageReceiverHealthController()
        var snapshot = healthySnapshot(activeQuality: 0.62)
        snapshot.clientPresentationStallCount = 1
        snapshot.clientWorstPresentationGapMs = 900

        for sampleIndex in 0 ..< 4 {
            let action = controller.advance(
                snapshots: [snapshot],
                currentBitrateBps: 48_000_000,
                ceilingBps: 48_000_000,
                now: 10 + Double(sampleIndex * 2),
                usesCadenceDeliveryPressure: false
            )
            #expect(action == .none)
        }

        #expect(controller.state == .stable)
        #expect(controller.lastTransportPressureReason == nil)
    }

    @Test("Automatic transport health backs off on stale receiver freshness")
    func automaticTransportHealthBacksOffOnStaleReceiverFreshness() {
        var controller = MirageReceiverHealthController()
        var snapshot = healthySnapshot(activeQuality: 0.62)
        snapshot.pendingFrameCount = 3
        snapshot.clientPendingFrameAgeMs = 650

        _ = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 48_000_000,
            ceilingBps: 136_000_000,
            now: 10,
            usesCadenceDeliveryPressure: false
        )
        let action = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 48_000_000,
            ceilingBps: 136_000_000,
            now: 12,
            usesCadenceDeliveryPressure: false
        )

        #expect(action == .backoff(targetBitrateBps: 40_800_000))
        #expect(
            controller.lastTransportPressureReason ==
                "client freshness debt pendingAge=650.0ms displayDebt=0.0ms/0.0ms " +
                "presentationGap=0.0ms stalls=0 reassemblerFrames=0 reassemblerBytes=0B"
        )
    }

    @Test("Support-log receive gaps back off without explicit drops")
    func supportLogReceiveGapsBackOffWithoutExplicitDrops() {
        var controller = MirageReceiverHealthController()
        var snapshot = healthySnapshot(activeQuality: 0.62)
        snapshot.hostEncodedFPS = 60
        snapshot.receivedFPS = 30
        snapshot.decodedFPS = 30
        snapshot.submittedFPS = 30
        snapshot.uniqueSubmittedFPS = 30
        snapshot.clientReceivedWorstGapMs = 216
        snapshot.clientReceivedFrameIntervalP95Ms = 55
        snapshot.clientReceivedFrameIntervalP99Ms = 150

        _ = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 48_000_000,
            ceilingBps: 136_000_000,
            now: 10
        )
        let action = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 48_000_000,
            ceilingBps: 136_000_000,
            now: 12
        )

        #expect(action == .backoff(targetBitrateBps: 40_800_000))
        #expect(
            controller.lastTransportPressureReason ==
                "client delivery cadence host=60.0fps received=30.0fps worstGap=216.0ms p95=55.0ms p99=150.0ms"
        )
    }

    @Test("Encode-limited host cadence does not back off receiver health")
    func encodeLimitedHostCadenceDoesNotBackOffReceiverHealth() {
        var controller = MirageReceiverHealthController()
        var snapshot = healthySnapshot(activeQuality: 0.62)
        snapshot.hostCaptureFPS = 60
        snapshot.hostEncodeAttemptFPS = 60
        snapshot.hostEncodedFPS = 30
        snapshot.receivedFPS = 30
        snapshot.decodedFPS = 30
        snapshot.submittedFPS = 30
        snapshot.uniqueSubmittedFPS = 30
        snapshot.clientReceivedWorstGapMs = 34
        snapshot.clientReceivedFrameIntervalP95Ms = 34
        snapshot.clientReceivedFrameIntervalP99Ms = 40

        for sampleIndex in 0 ..< 4 {
            let action = controller.advance(
                snapshots: [snapshot],
                currentBitrateBps: 48_000_000,
                ceilingBps: 48_000_000,
                now: 10 + Double(sampleIndex * 2)
            )
            #expect(action == .none)
        }

        #expect(controller.state == .stable)
        #expect(controller.lastTransportPressureReason == nil)
    }

    @Test("Missing host metrics hold")
    func missingHostMetricsHold() {
        var controller = MirageReceiverHealthController()
        var snapshot = healthySnapshot(activeQuality: 0.62)
        snapshot.hasHostMetrics = false

        let action = controller.advance(
            snapshots: [snapshot],
            currentBitrateBps: 20_000_000,
            ceilingBps: 80_000_000,
            now: 10
        )

        #expect(action == .none)
        #expect(controller.state == .stable)
    }

    @Test("AWDL route health ignores non-AWDL starts")
    func awdlRouteHealthIgnoresNonAwdlStarts() {
        var controller = MirageAwdlRouteHealthController(
            startedOnAwdl: false,
            startupBitrateBps: 80_000_000,
            now: 0
        )
        var snapshot = healthySnapshot(activeQuality: 0.62)
        snapshot.clientReassemblerForwardGapTimeouts = 2
        snapshot.clientReceivedWorstGapMs = 1_500

        let decision = controller.advance(
            snapshots: [snapshot],
            currentPathKind: .awdl,
            currentBitrateBps: 32_000_000,
            now: 120
        )

        #expect(decision == nil)
    }

    @Test("AWDL route health demotes after sustained degradation")
    func awdlRouteHealthDemotesAfterSustainedDegradation() throws {
        var controller = MirageAwdlRouteHealthController(
            startedOnAwdl: true,
            startupBitrateBps: 80_000_000,
            now: 0
        )
        var snapshot = healthySnapshot(activeQuality: 0.62)
        snapshot.clientPFrameCompletionLatencyP95Ms = 300

        for sampleIndex in 0 ..< 3 {
            let decision = controller.advance(
                snapshots: [snapshot],
                currentPathKind: .awdl,
                currentBitrateBps: 12_000_000,
                now: 92 + Double(sampleIndex * 2)
            )
            #expect(decision == nil)
        }

        let emittedDecision = controller.advance(
            snapshots: [snapshot],
            currentPathKind: .awdl,
            currentBitrateBps: 12_000_000,
            now: 98
        )
        let decision = try #require(emittedDecision)

        #expect(decision.degradedSampleCount == 4)
        #expect(decision.reason.contains("bitrate collapsed"))
    }

    @Test("AWDL route health waits through early severe startup blips")
    func awdlRouteHealthWaitsThroughEarlySevereStartupBlips() throws {
        var controller = MirageAwdlRouteHealthController(
            startedOnAwdl: true,
            startupBitrateBps: 80_000_000,
            now: 0
        )
        var snapshot = healthySnapshot(activeQuality: 0.62)
        snapshot.clientReassemblerForwardGapTimeouts = 2
        snapshot.clientReceivedWorstGapMs = 1_500

        let earlyDecision = controller.advance(
            snapshots: [snapshot],
            currentPathKind: .awdl,
            currentBitrateBps: 70_000_000,
            now: 20
        )
        #expect(earlyDecision == nil)

        let secondEarlyDecision = controller.advance(
            snapshots: [snapshot],
            currentPathKind: .awdl,
            currentBitrateBps: 70_000_000,
            now: 32
        )
        let thirdEarlyDecision = controller.advance(
            snapshots: [snapshot],
            currentPathKind: .awdl,
            currentBitrateBps: 70_000_000,
            now: 34
        )

        #expect(secondEarlyDecision == nil)
        #expect(thirdEarlyDecision == nil)
    }

    @Test("AWDL route health demotes early for startup decode collapse")
    func awdlRouteHealthDemotesEarlyForStartupDecodeCollapse() throws {
        var controller = MirageAwdlRouteHealthController(
            startedOnAwdl: true,
            startupBitrateBps: 16_000_000,
            now: 0
        )
        var snapshot = healthySnapshot(activeQuality: 0.62)
        snapshot.clientDecodeBacklogFrameCount = 36

        let beforeWatchdogDecision = controller.advance(
            snapshots: [snapshot],
            currentPathKind: .awdl,
            currentBitrateBps: 16_000_000,
            now: 7
        )
        let firstDecision = controller.advance(
            snapshots: [snapshot],
            currentPathKind: .awdl,
            currentBitrateBps: 16_000_000,
            now: 15
        )
        let secondDecision = controller.advance(
            snapshots: [snapshot],
            currentPathKind: .awdl,
            currentBitrateBps: 16_000_000,
            now: 17
        )

        #expect(beforeWatchdogDecision == nil)
        #expect(firstDecision == nil)
        #expect(secondDecision != nil)
    }

    @Test("AWDL route health ignores a one-time startup drop burst")
    func awdlRouteHealthIgnoresOneTimeStartupDropBurst() throws {
        var controller = MirageAwdlRouteHealthController(
            startedOnAwdl: true,
            startupBitrateBps: 16_000_000,
            now: 0
        )
        // A single startup keyframe catch-up burst leaves the cumulative
        // dropped-frame counter > 0 for the rest of the stream. A one-time
        // burst must not be read as ongoing early-startup failure on every
        // later tick, otherwise a healthy AWDL link is evicted ~17s in.
        var snapshot = healthySnapshot(activeQuality: 0.62)
        snapshot.clientDroppedFrames = 37

        let baseline = controller.advance(
            snapshots: [snapshot],
            currentPathKind: .awdl,
            currentBitrateBps: 16_000_000,
            now: 5
        )
        let firstInWindow = controller.advance(
            snapshots: [snapshot],
            currentPathKind: .awdl,
            currentBitrateBps: 16_000_000,
            now: 16
        )
        let secondInWindow = controller.advance(
            snapshots: [snapshot],
            currentPathKind: .awdl,
            currentBitrateBps: 16_000_000,
            now: 18
        )

        #expect(baseline == nil)
        #expect(firstInWindow == nil)
        #expect(secondInWindow == nil)
    }

    @Test("AWDL route health still demotes on sustained new drops")
    func awdlRouteHealthDemotesOnSustainedNewDrops() throws {
        var controller = MirageAwdlRouteHealthController(
            startedOnAwdl: true,
            startupBitrateBps: 16_000_000,
            now: 0
        )
        // New drops accruing on every tick (a genuinely failing link) must
        // still demote.
        var snapshot = healthySnapshot(activeQuality: 0.62)
        snapshot.clientDroppedFrames = 5

        _ = controller.advance(
            snapshots: [snapshot],
            currentPathKind: .awdl,
            currentBitrateBps: 16_000_000,
            now: 5
        )
        snapshot.clientDroppedFrames = 12
        let firstInWindow = controller.advance(
            snapshots: [snapshot],
            currentPathKind: .awdl,
            currentBitrateBps: 16_000_000,
            now: 16
        )
        snapshot.clientDroppedFrames = 20
        let secondInWindow = controller.advance(
            snapshots: [snapshot],
            currentPathKind: .awdl,
            currentBitrateBps: 16_000_000,
            now: 18
        )

        #expect(firstInWindow == nil)
        #expect(secondInWindow != nil)
    }

    func healthySnapshot(activeQuality: Double) -> MirageDiagnostics.MirageClientMetricsSnapshot {
        var snapshot = MirageDiagnostics.MirageClientMetricsSnapshot(
            decodedFPS: 60,
            receivedFPS: 60,
            submittedFPS: 60,
            uniqueSubmittedFPS: 60,
            pendingFrameCount: 0,
            decodeHealthy: true,
            hostActiveQuality: activeQuality,
            hostTargetFrameRate: 60,
            hasHostMetrics: true
        )
        snapshot.hostSendQueueBytes = 0
        snapshot.hostSendStartDelayAverageMs = 0
        snapshot.hostSendCompletionAverageMs = 0
        snapshot.hostPacketPacerAverageSleepMs = 0
        snapshot.hostStalePacketDrops = 0
        snapshot.hostSenderLocalDeadlineDrops = 0
        snapshot.hostGenerationAbortDrops = 0
        snapshot.hostNonKeyframeHoldDrops = 0
        snapshot.hostCaptureIngressFPS = 60
        snapshot.hostCaptureFPS = 60
        snapshot.hostEncodeAttemptFPS = 60
        snapshot.hostEncodedFPS = 60
        snapshot.hostFrameBudgetMs = 16.67
        snapshot.hostAverageEncodeMs = 10
        return snapshot
    }

    private func severeTransportSnapshot() -> MirageDiagnostics.MirageClientMetricsSnapshot {
        var snapshot = healthySnapshot(activeQuality: 0.62)
        snapshot.hostSendQueueBytes = 2_500_000
        snapshot.hostSendStartDelayAverageMs = 9
        snapshot.hostSendCompletionAverageMs = 35
        snapshot.hostPacketPacerAverageSleepMs = 2.5
        snapshot.hostStalePacketDrops = 24
        return snapshot
    }

    private func delayOnlySnapshot() -> MirageDiagnostics.MirageClientMetricsSnapshot {
        var snapshot = healthySnapshot(activeQuality: 0.62)
        snapshot.hostSendStartDelayAverageMs = 4.5
        snapshot.hostSendCompletionAverageMs = 20
        return snapshot
    }

    private func startupQueueSpikeSnapshot() -> MirageDiagnostics.MirageClientMetricsSnapshot {
        var snapshot = healthySnapshot(activeQuality: 0.62)
        snapshot.hostSendQueueBytes = 2_500_000
        snapshot.hostSendStartDelayAverageMs = 9
        snapshot.hostSendCompletionAverageMs = 35
        snapshot.hostPacketPacerAverageSleepMs = 2.5
        snapshot.hostStalePacketDrops = 0
        snapshot.hostSenderLocalDeadlineDrops = 0
        return snapshot
    }

    private func decodeStalledButTransportHealthySnapshot() -> MirageDiagnostics.MirageClientMetricsSnapshot {
        var snapshot = healthySnapshot(activeQuality: 0.62)
        snapshot.decodedFPS = 0
        snapshot.submittedFPS = 0
        snapshot.uniqueSubmittedFPS = 0
        snapshot.decodeHealthy = false
        return snapshot
    }

    func remoteKeyframeStarvedSnapshot() -> MirageDiagnostics.MirageClientMetricsSnapshot {
        var snapshot = healthySnapshot(activeQuality: 0.62)
        snapshot.receivedFPS = 0
        snapshot.decodedFPS = 0
        snapshot.submittedFPS = 0
        snapshot.uniqueSubmittedFPS = 0
        snapshot.decodeHealthy = false
        snapshot.clientReassemblerPendingKeyframeCount = 2
        snapshot.clientDroppedFrames = 1
        return snapshot
    }

    private func captureBoundButTransportHealthySnapshot() -> MirageDiagnostics.MirageClientMetricsSnapshot {
        var snapshot = healthySnapshot(activeQuality: 0.70)
        snapshot.hostCaptureIngressFPS = 44
        snapshot.hostCaptureFPS = 43
        snapshot.hostEncodeAttemptFPS = 43
        snapshot.hostEncodedFPS = 43
        snapshot.receivedFPS = 43
        snapshot.decodedFPS = 43
        snapshot.submittedFPS = 43
        snapshot.uniqueSubmittedFPS = 43
        return snapshot
    }

    private func presentationBoundButTransportHealthySnapshot() -> MirageDiagnostics.MirageClientMetricsSnapshot {
        var snapshot = healthySnapshot(activeQuality: 0.62)
        snapshot.submittedFPS = 43
        snapshot.uniqueSubmittedFPS = 43
        snapshot.clientOverwrittenPendingFrames = 2
        snapshot.clientDisplayLayerNotReadyCount = 1
        snapshot.clientPendingFrameAgeMs = 24
        return snapshot
    }
}
#endif
