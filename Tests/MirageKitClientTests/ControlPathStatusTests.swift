//
//  ControlPathStatusTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/29/26.
//

@testable import MirageKit
@testable import MirageKitClient
import MirageDiagnostics
import Testing
import MirageConnectivity
import MirageCore
import MirageMedia
import MirageWire

@Suite("Control Path Status")
struct ControlPathStatusTests {
    @MainActor
    @Test("Control path update publishes stored status and history")
    func controlPathUpdatePublishesStoredStatusAndHistory() throws {
        let service = MirageClientService(deviceName: "Control Path Test")
        let snapshot = Self.snapshot(interfaceNames: ["en0"], usesWiFi: true)

        service.handleControlPathUpdate(snapshot)

        let status = try #require(service.currentControlPathStatus)
        #expect(service.currentControlPathKind == .wifi)
        #expect(status.kind == .wifi)
        #expect(status.interfaceNames == ["en0"])
        #expect(service.controlPathHistory.map(\.status) == [status])

        service.handleControlPathUpdate(snapshot)

        #expect(service.controlPathHistory.map(\.status) == [status])
    }

    @MainActor
    @Test("Clearing control path resets stored status and history")
    func clearingControlPathResetsStoredStatusAndHistory() {
        let service = MirageClientService(deviceName: "Control Path Clear Test")
        service.handleControlPathUpdate(Self.snapshot(interfaceNames: ["en0"], usesWiFi: true))

        service.clearControlPathState()

        #expect(service.currentControlPathKind == nil)
        #expect(service.currentControlPathStatus == nil)
        #expect(service.controlPathHistory.isEmpty)
    }

    @MainActor
    @Test("Stored status preserves USB-C proximity classification")
    func storedStatusPreservesUSBCProximityClassification() throws {
        let service = MirageClientService(deviceName: "Control Path Proximity Test")
        let snapshot = Self.snapshot(interfaceNames: ["anpi0"], usesOther: true)

        service.handleControlPathUpdate(snapshot)

        let status = try #require(service.currentControlPathStatus)
        #expect(service.currentControlPathKind == .wired)
        #expect(status.usesUSBProximityInterface)
        #expect(status.usesProximityWiredLikePolicy)
    }

    @MainActor
    @Test("AWDL path kind activates radio policy when profile is unknown")
    func awdlPathKindActivatesRadioPolicyWhenProfileIsUnknown() {
        let service = MirageClientService(deviceName: "Control Path AWDL Fallback Test")
        let snapshot = Self.manualSnapshot(kind: .awdl, mediaProfile: .unknown)

        service.handleControlPathUpdate(snapshot)

        #expect(service.currentMediaPathUsesAwdlRadioPolicy)
        #expect(service.effectiveLatencyModeForCurrentMediaPath(.lowestLatency) == .balanced)
        #expect(service.effectiveHostBufferingPolicyForCurrentMediaPath(.freshestFrame) == .stability)
        #expect(service.effectiveFrameRateForCurrentMediaPath(120) == MirageAwdlMediaController.awdlRadioFrameRate)
    }

    @MainActor
    @Test("AWDL path kind preserves resolved proximity wired media policy")
    func awdlPathKindPreservesResolvedProximityWiredMediaPolicy() {
        let service = MirageClientService(deviceName: "Control Path AWDL Proximity Test")
        let snapshot = Self.manualSnapshot(kind: .awdl, mediaProfile: .proximityWiredLike)

        service.handleControlPathUpdate(snapshot)

        #expect(!service.currentMediaPathUsesAwdlRadioPolicy)
        #expect(service.effectiveLatencyModeForCurrentMediaPath(.lowestLatency) == .lowestLatency)
        #expect(service.effectiveHostBufferingPolicyForCurrentMediaPath(.freshestFrame) == .freshestFrame)
        #expect(service.effectiveFrameRateForCurrentMediaPath(120) == 120)
    }

    @MainActor
    @Test("LLW path kind uses local WiFi media policy")
    func llwPathKindUsesLocalWiFiMediaPolicy() {
        let service = MirageClientService(deviceName: "Control Path LLW Test")
        let snapshot = Self.snapshot(interfaceNames: ["llw0"], usesWiFi: true)

        service.handleControlPathUpdate(snapshot)

        #expect(service.currentControlPathKind == .wifi)
        #expect(!service.currentMediaPathUsesAwdlRadioPolicy)
        #expect(service.effectiveLatencyModeForCurrentMediaPath(.lowestLatency) == .lowestLatency)
        #expect(service.effectiveHostBufferingPolicyForCurrentMediaPath(.freshestFrame) == .freshestFrame)
        #expect(service.effectiveFrameRateForCurrentMediaPath(120) == 120)
    }

    @Test("Host metrics preserve unsupported realtime transport drops")
    func hostMetricsPreserveUnsupportedRealtimeTransportDrops() throws {
        let store = MirageClientMetricsStore()
        let streamID: StreamID = 42
        store.updateHostPipelineMetrics(MirageWire.StreamMetricsMessage(
            streamID: streamID,
            encodedFPS: 60,
            idleEncodedFPS: 0,
            droppedFrames: 0,
            activeQuality: 0.5,
            targetFrameRate: 60,
            stalePacketDrops: 11,
            senderLocalDeadlineDrops: 13,
            queuedUnreliableDeadlineExpiredDrops: 2,
            queuedUnreliableQueueLimitDrops: 3,
            queuedUnreliableSupersededDrops: 5,
            queuedUnreliableUnsupportedTransportDrops: 7,
            queuedUnreliableClosedDrops: 11,
            queuedUnreliablePendingPackets: 17,
            queuedUnreliableOutstandingPackets: 19,
            queuedUnreliableQueuedBytes: 23_000,
            queuedUnreliablePendingPacketMax: 29,
            queuedUnreliableOutstandingPacketMax: 31,
            queuedUnreliableQueuedBytesMax: 37_000,
            queuedUnreliableEnqueuedCount: 41,
            queuedUnreliableSentCount: 43,
            queuedUnreliableCompletedCount: 47,
            queuedUnreliableDroppedCount: 53,
            queuedUnreliableErrorCount: 59,
            queuedUnreliableQueueDwellP99Ms: 3.25,
            queuedUnreliableSendGapP99Ms: 1.5,
            queuedUnreliableContentProcessedP99Ms: 4.75
        ))

        let snapshot = try #require(store.snapshot(for: streamID))
        let queuedDrops = try #require(snapshot.hostQueuedUnreliableDropCounts)
        #expect(queuedDrops.deadlineExpired == 2)
        #expect(queuedDrops.queueLimit == 3)
        #expect(queuedDrops.superseded == 5)
        #expect(queuedDrops.unsupportedTransport == 7)
        #expect(queuedDrops.closed == 11)
        #expect(queuedDrops.total == 28)
        #expect((snapshot.hostStalePacketDrops ?? 0) + (snapshot.hostSenderLocalDeadlineDrops ?? 0) + queuedDrops.total == 52)
    }

    @Test("Host metrics preserve AWDL policy telemetry")
    func hostMetricsPreserveAwdlPolicyTelemetry() throws {
        let store = MirageClientMetricsStore()
        let streamID: StreamID = 43
        store.updateHostMetrics(MirageWire.StreamMetricsMessage(
            streamID: streamID,
            encodedFPS: 45,
            idleEncodedFPS: 0,
            droppedFrames: 0,
            activeQuality: 0.42,
            targetFrameRate: 45,
            awdlPolicyState: "demoted",
            awdlPolicyTrigger: "p-frame-latency",
            awdlSelectedLever: "resolution",
            awdlPlayoutDelayMs: 80,
            awdlResolutionScale: 0.875,
            awdlQualityReductionAllowed: false,
            awdlHostPacingBudgetBps: 22_000_000
        ))

        let snapshot = try #require(store.snapshot(for: streamID))
        #expect(snapshot.hostAwdlPolicyState == "demoted")
        #expect(snapshot.hostAwdlPolicyTrigger == "p-frame-latency")
        #expect(snapshot.hostAwdlSelectedLever == "resolution")
        #expect(snapshot.hostAwdlPlayoutDelayMs == 80)
        #expect(snapshot.hostAwdlResolutionScale == 0.875)
        #expect(snapshot.hostAwdlQualityReductionAllowed == false)
        #expect(snapshot.hostAwdlPacingBudgetBps == 22_000_000)
        #expect(snapshot.hasHostMetrics)
    }

    @Test("Host metrics preserve readability protection telemetry")
    func hostMetricsPreserveReadabilityProtectionTelemetry() throws {
        let store = MirageClientMetricsStore()
        let streamID: StreamID = 45
        store.updateHostMetrics(StreamMetricsMessage(
            streamID: streamID,
            encodedFPS: 42,
            idleEncodedFPS: 0,
            droppedFrames: 3,
            activeQuality: 0.50,
            targetFrameRate: 60,
            highRefreshPacingSkips: 4,
            highRefreshPacingMode: "protecting",
            highRefreshPacingReason: "stale-frame",
            highRefreshPacingFloorFPS: 60,
            readabilityProtectionSkips: 3,
            readabilityProtectionMode: "protecting",
            readabilityProtectionReason: "encoder-lag",
            readabilityProtectionAdmitTargetFPS: 20,
            runtimeQualityFloor: 0.50,
            runtimeQualityCeiling: 0.52
        ))

        let snapshot = try #require(store.snapshot(for: streamID))
        #expect(snapshot.hostHighRefreshPacingSkips == 4)
        #expect(snapshot.hostHighRefreshPacingMode == "protecting")
        #expect(snapshot.hostHighRefreshPacingReason == "stale-frame")
        #expect(snapshot.hostHighRefreshPacingFloorFPS == 60)
        #expect(snapshot.hostReadabilityProtectionSkips == 3)
        #expect(snapshot.hostReadabilityProtectionMode == "protecting")
        #expect(snapshot.hostReadabilityProtectionReason == "encoder-lag")
        #expect(snapshot.hostReadabilityProtectionAdmitTargetFPS == 20)
        #expect(abs((snapshot.hostRuntimeQualityFloor ?? 0) - 0.50) < 0.001)
        #expect(abs((snapshot.hostRuntimeQualityCeiling ?? 0) - 0.52) < 0.001)
        #expect(snapshot.hasHostMetrics)
    }

    @MainActor
    @Test("Diagnostics context includes complete AWDL host transport drop telemetry")
    func diagnosticsContextIncludesCompleteAwdlHostTransportDropTelemetry() {
        let service = MirageClientService(deviceName: "Control Path Diagnostics Test")
        let streamID: StreamID = 44
        service.desktopStreamID = streamID
        service.metricsStore.updateHostPipelineMetrics(MirageWire.StreamMetricsMessage(
            streamID: streamID,
            encodedFPS: 60,
            idleEncodedFPS: 0,
            droppedFrames: 0,
            activeQuality: 0.5,
            targetFrameRate: 60,
            stalePacketDrops: 11,
            senderLocalDeadlineDrops: 13,
            queuedUnreliableDeadlineExpiredDrops: 2,
            queuedUnreliableQueueLimitDrops: 3,
            queuedUnreliableSupersededDrops: 5,
            queuedUnreliableUnsupportedTransportDrops: 7,
            queuedUnreliableClosedDrops: 11,
            queuedUnreliablePendingPackets: 17,
            queuedUnreliableOutstandingPackets: 19,
            queuedUnreliableQueuedBytes: 23_000,
            queuedUnreliablePendingPacketMax: 29,
            queuedUnreliableOutstandingPacketMax: 31,
            queuedUnreliableQueuedBytesMax: 37_000,
            queuedUnreliableEnqueuedCount: 41,
            queuedUnreliableSentCount: 43,
            queuedUnreliableCompletedCount: 47,
            queuedUnreliableDroppedCount: 53,
            queuedUnreliableErrorCount: 59,
            queuedUnreliableQueueDwellP99Ms: 3.25,
            queuedUnreliableSendGapP99Ms: 1.5,
            queuedUnreliableContentProcessedP99Ms: 4.75
        ))

        let diagnostics = service.diagnosticsContextSnapshot

        #expect(diagnostics["client.primaryStream.hostQueuedUnreliableDeadlineExpiredDrops"] == .int(2))
        #expect(diagnostics["client.primaryStream.hostQueuedUnreliableQueueLimitDrops"] == .int(3))
        #expect(diagnostics["client.primaryStream.hostQueuedUnreliableSupersededDrops"] == .int(5))
        #expect(diagnostics["client.primaryStream.hostQueuedUnreliableUnsupportedTransportDrops"] == .int(7))
        #expect(diagnostics["client.primaryStream.hostQueuedUnreliableClosedDrops"] == .int(11))
        #expect(diagnostics["client.primaryStream.hostQueuedUnreliableDropCount"] == .int(28))
        #expect(diagnostics["client.primaryStream.hostQueuedUnreliablePendingPackets"] == .int(17))
        #expect(diagnostics["client.primaryStream.hostQueuedUnreliableOutstandingPackets"] == .int(19))
        #expect(diagnostics["client.primaryStream.hostQueuedUnreliableQueuedBytes"] == .int(23_000))
        #expect(diagnostics["client.primaryStream.hostQueuedUnreliablePendingPacketMax"] == .int(29))
        #expect(diagnostics["client.primaryStream.hostQueuedUnreliableOutstandingPacketMax"] == .int(31))
        #expect(diagnostics["client.primaryStream.hostQueuedUnreliableQueuedBytesMax"] == .int(37_000))
        #expect(diagnostics["client.primaryStream.hostQueuedUnreliableEnqueuedCount"] == .int(41))
        #expect(diagnostics["client.primaryStream.hostQueuedUnreliableSentCount"] == .int(43))
        #expect(diagnostics["client.primaryStream.hostQueuedUnreliableCompletedCount"] == .int(47))
        #expect(diagnostics["client.primaryStream.hostQueuedUnreliableDroppedCount"] == .int(53))
        #expect(diagnostics["client.primaryStream.hostQueuedUnreliableErrorCount"] == .int(59))
        #expect(diagnostics["client.primaryStream.hostQueuedUnreliableQueueDwellP99Ms"] == .double(3.25))
        #expect(diagnostics["client.primaryStream.hostQueuedUnreliableSendGapP99Ms"] == .double(1.5))
        #expect(diagnostics["client.primaryStream.hostQueuedUnreliableContentProcessedP99Ms"] == .double(4.75))
        #expect(diagnostics["client.primaryStream.hostTransportPressureDropCount"] == .int(52))
    }

    private static func snapshot(
        interfaceNames: [String],
        usesWiFi: Bool = false,
        usesWired: Bool = false,
        usesCellular: Bool = false,
        usesLoopback: Bool = false,
        usesOther: Bool = false
    ) -> MirageConnectivity.MirageNetworkPathSnapshot {
        MirageConnectivity.MirageNetworkPathClassifier.classify(
            interfaceNames: interfaceNames,
            usesWiFi: usesWiFi,
            usesWired: usesWired,
            usesCellular: usesCellular,
            usesLoopback: usesLoopback,
            usesOther: usesOther,
            status: "satisfied",
            isExpensive: false,
            isConstrained: false,
            supportsIPv4: true,
            supportsIPv6: true
        )
    }

    private static func manualSnapshot(
        kind: MirageCore.MirageNetworkPathKind,
        mediaProfile: MirageMedia.MirageMediaPathProfile
    ) -> MirageConnectivity.MirageNetworkPathSnapshot {
        MirageConnectivity.MirageNetworkPathSnapshot(
            kind: kind,
            mediaProfile: mediaProfile,
            status: "satisfied",
            signature: "manual|\(kind.rawValue)|\(mediaProfile.rawValue)",
            interfaceNames: [],
            isExpensive: false,
            isConstrained: false,
            supportsIPv4: true,
            supportsIPv6: true,
            usesWiFi: false,
            usesWired: false,
            usesCellular: false,
            usesLoopback: false,
            usesOther: false,
            localEndpointDescription: nil,
            remoteEndpointDescription: nil
        )
    }
}
