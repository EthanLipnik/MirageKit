//
//  MirageHostService+QualityTest.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/2/26.
//
//  Host-side quality test handling.
//

import Loom
import MirageKit

#if os(macOS)
@MainActor
extension MirageHostService {
    nonisolated static let qualityTestResetQueueProfiles: [LoomQueuedUnreliableSendProfile] = [
        .interactiveMedia,
        .throughputProbe,
    ]
    nonisolated static let qualityTestMinimumTickIntervalSeconds = 0.00025
    nonisolated static let qualityTestMaximumBurstPackets = 4_096
    nonisolated static let qualityTestReplayFrameRate = 60
    nonisolated static let qualityTestReplayKeyframeMultiplier = 8.0
    nonisolated static let qualityTestDeliveryFloor = 0.90

    /// Returns whether the quality-test sender can queue another packet without exceeding Loom limits.
    nonisolated static func qualityTestCanEnqueuePacket(
        outstandingPackets: Int,
        outstandingBytes: Int,
        packetBytes: Int,
        profile: LoomQueuedUnreliableSendProfile = .throughputProbe
    ) -> Bool {
        let limits = profile.recommendedLimits
        guard packetBytes > 0 else { return true }
        if outstandingPackets >= limits.maxOutstandingPackets {
            return false
        }
        if outstandingPackets == 0 {
            return true
        }
        return outstandingBytes + packetBytes <= limits.maxOutstandingBytes
    }

    /// Selects the Loom queue profile that matches the quality-test probe behavior.
    nonisolated static func qualityTestQueueProfile(
        for probeKind: MirageQualityTestPlan.ProbeKind
    ) -> LoomQueuedUnreliableSendProfile {
        switch probeKind {
        case .transport:
            .throughputProbe
        case .streamingReplay:
            .interactiveMedia
        }
    }

    /// Returns whether a stage underdelivered its fixed measurement window.
    nonisolated static func qualityTestMissedDeliveryWindow(
        targetBitrateBps: Int,
        measurementDurationMs: Int,
        payloadBytes: Int,
        packetBytes: Int,
        sentPayloadBytes: Int,
        encounteredEnqueueBackpressure: Bool,
        outstandingPacketsAfterSettle: Int
    ) -> Bool {
        if encounteredEnqueueBackpressure || outstandingPacketsAfterSettle > 0 {
            return true
        }
        guard
            targetBitrateBps > 0,
            measurementDurationMs > 0,
            payloadBytes > 0,
            packetBytes > 0
        else {
            return false
        }

        let payloadRatio = Double(payloadBytes) / Double(packetBytes)
        let expectedPayloadBps = Double(targetBitrateBps) * payloadRatio
        let deliveredPayloadBps = Double(sentPayloadBytes * 8) / (Double(measurementDurationMs) / 1000.0)
        return deliveredPayloadBps < expectedPayloadBps * qualityTestDeliveryFloor
    }

    /// Returns whether a quality-test sweep should stop after the current stage.
    nonisolated static func qualityTestShouldTerminateSweep(
        stopAfterFirstBreach: Bool,
        deliveryWindowMissed: Bool
    ) -> Bool {
        stopAfterFirstBreach && deliveryWindowMissed
    }

    func handleQualityTestRequest(
        _ message: ControlMessage,
        from clientContext: ClientContext
    ) async {
        let request: QualityTestRequestMessage
        do {
            request = try message.decode(QualityTestRequestMessage.self)
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to decode quality test request: ")
            return
        }

        let client = clientContext.client
        await cancelQualityTest(for: client.id, reason: "superseded by new quality-test request")
        qualityTestSessionTokensByClientID[client.id] = UUID()
        qualityTestIDsByClientID[client.id] = request.testID
        let sessionToken = qualityTestSessionTokensByClientID[client.id] ?? UUID()

        let pathKind = clientContext.pathSnapshot.map { MirageNetworkPathClassifier.classify($0).kind }
        let acceptedMediaMaxPacketSize = mirageNegotiatedMediaMaxPacketSize(
            requested: request.mediaMaxPacketSize,
            pathKind: pathKind
        )
        let payloadBytes = min(
            request.payloadBytes,
            miragePayloadSize(maxPacketSize: acceptedMediaMaxPacketSize)
        )

        let qualityStream: LoomMultiplexedStream
        do {
            qualityStream = try await clientContext.controlChannel.session.openStream(
                label: "quality-test/\(request.testID)"
            )
        } catch {
            MirageLogger.host("Quality test skipped - failed to open Loom stream for client \(client.name): \(error)")
            return
        }
        qualityTestStreamsByClientID[client.id] = qualityStream

        let hostCaptureCapability = hostCaptureCapabilityProvider?()
        let task = Task.detached(
            priority: .userInitiated
        ) { [weak self, clientContext, request, qualityStream, hostCaptureCapability] in
            defer {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.qualityTestSessionTokensByClientID[client.id] == sessionToken else { return }
                    self.qualityTestTasksByClientID.removeValue(forKey: client.id)
                    self.qualityTestSessionTokensByClientID.removeValue(forKey: client.id)
                    self.qualityTestIDsByClientID.removeValue(forKey: client.id)
                    await self.closeQualityTestStream(for: client.id)
                }
            }

            await Self.runQualityTestSession(
                request: request,
                payloadBytes: payloadBytes,
                via: qualityStream,
                clientContext: clientContext,
                hostCaptureCapability: hostCaptureCapability
            )
        }
        qualityTestTasksByClientID[client.id] = task
    }

    func closeQualityTestStream(
        for clientID: UUID,
        resetQueuedSends: Bool = false
    ) async {
        guard let stream = qualityTestStreamsByClientID.removeValue(forKey: clientID) else {
            return
        }
        if resetQueuedSends {
            for profile in Self.qualityTestResetQueueProfiles {
                await stream.resetQueuedUnreliableSends(profile: profile)
            }
        }
        do {
            try await stream.close()
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to close quality test stream for client \(clientID): ")
        }
    }

    func handleQualityTestCancel(
        _ message: ControlMessage,
        from clientContext: ClientContext
    ) async {
        let request: QualityTestCancelMessage
        do {
            request = try message.decode(QualityTestCancelMessage.self)
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to decode quality test cancellation request: ")
            return
        }

        await cancelQualityTest(
            for: clientContext.client.id,
            expectedTestID: request.testID,
            reason: "client requested cancellation"
        )
    }

    func cancelQualityTest(
        for clientID: UUID,
        expectedTestID: UUID? = nil,
        reason: String
    ) async {
        if let expectedTestID,
           let activeTestID = qualityTestIDsByClientID[clientID],
           activeTestID != expectedTestID {
            MirageLogger.host(
                "Ignoring stale quality-test cancellation for client \(clientID) expected=\(expectedTestID.uuidString) active=\(activeTestID.uuidString)"
            )
            return
        }

        let activeTestID = qualityTestIDsByClientID.removeValue(forKey: clientID)
        let sessionToken = qualityTestSessionTokensByClientID.removeValue(forKey: clientID)
        let task = qualityTestTasksByClientID.removeValue(forKey: clientID)
        let hasActiveStream = qualityTestStreamsByClientID[clientID] != nil

        guard activeTestID != nil || sessionToken != nil || task != nil || hasActiveStream else {
            return
        }

        task?.cancel()
        await closeQualityTestStream(for: clientID, resetQueuedSends: true)

        let testDescription = activeTestID?.uuidString ?? "unknown"
        MirageLogger.host(
            "Cancelled quality test for client \(clientID) testID=\(testDescription) reason=\(reason)"
        )
    }

}
#endif
