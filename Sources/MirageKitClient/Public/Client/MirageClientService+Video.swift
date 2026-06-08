//
//  MirageClientService+Video.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Media stream receive loops.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import Foundation
import Network

@MainActor
extension MirageClientService {
    // MARK: - Media Stream Listener

    /// Start listening for incoming media streams on the authenticated session.
    func startMediaStreamListener() {
        guard let session = loomSession else { return }
        stopMediaStreamListener()

        let serviceBox = WeakSendableBox(self)
        mediaStreamListenerTask = Task.detached(priority: .userInitiated) { [session, serviceBox] in
            let observer = session.makeIncomingStreamObserver()
            for await stream in observer {
                guard !Task.isCancelled else { break }
                guard let service = serviceBox.value else { break }
                guard await service.loomSession?.id == session.id else { break }
                guard let label = stream.label else {
                    MirageLogger.client(
                        "Ignoring incoming Loom stream with no label (id=\(stream.id))"
                    )
                    continue
                }
                await service.handleObservedIncomingMediaStream(
                    stream,
                    label: label,
                    sessionID: session.id
                )
            }
        }
    }

    /// Stop the media stream listener and all active media stream receive loops.
    func stopMediaStreamListener() {
        mediaStreamListenerTask?.cancel()
        mediaStreamListenerTask = nil
        cancelForegroundRecoveryMonitors()
        for (label, stream) in activeMediaStreams where label.hasPrefix("video/") {
            stream.clearIncomingBytesBatchHandler()
        }
        for task in videoStreamReceiveTasks.values {
            task.cancel()
        }
        videoStreamReceiveTasks.removeAll()
        for processor in videoPacketIngressProcessors.values {
            processor.finish()
        }
        videoPacketIngressProcessors.removeAll()
        fastPathState.clearAllBufferedEarlyVideoPackets()
        videoIngressTelemetryStore.clearAll()
        videoIngressLastDropCountByStream.removeAll(keepingCapacity: false)
        audioStreamReceiveTask?.cancel()
        audioStreamReceiveTask = nil
        activeMediaStreams.removeAll()
        refreshActiveStreamTransportBudgetPolicy()
    }

    // MARK: - Video Stream Receive

    /// Start receiving video packets from a multiplexed media stream.
    private func startVideoStreamReceiveLoop(
        stream: any MirageIncomingMediaStream,
        streamID: StreamID
    ) {
        videoStreamReceiveTasks[streamID]?.cancel()
        videoPacketIngressProcessors[streamID]?.finish()
        stream.clearIncomingBytesBatchHandler()
        videoPacketIngressProcessors.removeValue(forKey: streamID)
        let serviceBox = WeakSendableBox(self)
        videoIngressLastDropCountByStream[streamID] = 0
        videoIngressTelemetryStore.clear(streamID: streamID)

        switch MirageLatencyOptions.videoIngressMode() {
        case .direct:
            let telemetryStore = videoIngressTelemetryStore
            let telemetryRecorder = ClientVideoDirectIngressTelemetryRecorder()
            videoStreamReceiveTasks[streamID] = Task.detached(priority: .userInitiated) {
                [stream, streamID, serviceBox, telemetryStore, telemetryRecorder] in
                for await data in stream.incomingBytes {
                    guard !Task.isCancelled else { break }
                    telemetryStore.update(
                        telemetryRecorder.recordPacket(),
                        for: streamID
                    )
                    serviceBox.value?.processIncomingVideoData(data, expectedStreamID: streamID)
                }
                guard let service = serviceBox.value else { return }
                await service.finishVideoStreamReceiveLoop(streamID: streamID)
            }

        case .processor:
            let telemetryStore = videoIngressTelemetryStore
            let ingressProcessor = ClientVideoPacketIngressProcessor(streamID: streamID) { data, streamID in
                serviceBox.value?.processIncomingVideoData(data, expectedStreamID: streamID)
            }
            videoPacketIngressProcessors[streamID] = ingressProcessor
            stream.setIncomingBytesImmediateBatchHandler(maxBatchSize: 1) { [ingressProcessor, telemetryStore, streamID] batch in
                ingressProcessor.enqueue(batch)
                telemetryStore.update(ingressProcessor.snapshot(), for: streamID)
            }
            videoStreamReceiveTasks[streamID] = Task.detached(priority: .userInitiated) { [stream, streamID, serviceBox] in
                for await _ in stream.incomingBytes {
                    guard !Task.isCancelled else { break }
                }
                guard let service = serviceBox.value else { return }
                await service.finishVideoStreamReceiveLoop(streamID: streamID)
            }
        }
    }

    /// Process a single video packet received from a Loom stream.
    nonisolated func processIncomingVideoData(_ data: Data, expectedStreamID: StreamID) {
        if data.count >= MirageWire.mirageMosaicHeaderSize,
           let header = MirageWire.MirageMosaicPacketHeader.deserialize(from: data) {
            processIncomingMosaicVideoData(data, header: header, expectedStreamID: expectedStreamID)
            return
        }

        guard data.count >= MirageWire.mirageHeaderSize,
              let header = MirageWire.FrameHeader.deserialize(from: data) else {
            return
        }
        processIncomingFullFrameVideoData(data, header: header, expectedStreamID: expectedStreamID)
    }

    private nonisolated func processIncomingFullFrameVideoData(
        _ data: Data,
        header: MirageWire.FrameHeader,
        expectedStreamID: StreamID
    ) {
        let streamID = header.streamID
        guard streamID == expectedStreamID else {
            logFirstVideoPacketRejectionIfNeeded(
                .streamIDMismatch,
                expectedStreamID: expectedStreamID,
                actualStreamID: streamID
            )
            return
        }

        fastPathState.noteInboundMediaActivity()

        guard let packetContext = fastPathState.videoPacketContext(for: streamID) else {
            if fastPathState.bufferEarlyVideoPacket(data, for: streamID) {
                MirageLogger.client(
                    "Media stream \(streamID) buffered early startup video packet bytes=\(data.count)"
                )
            }
            logFirstVideoPacketRejectionIfNeeded(.packetContextMissing, expectedStreamID: streamID)
            return
        }

        if packetContext.consumedStartupPending {
            MirageLogger.client(
                "Media stream \(streamID) consumed startup-pending on first packet bytes=\(data.count)"
            )
            Task { @MainActor in
                self.logStartupFirstPacketIfNeeded(streamID: streamID)
                self.cancelStartupRegistrationRetry(streamID: streamID)
            }
        }

        guard let reassembler = packetContext.reassembler else {
            logFirstVideoPacketRejectionIfNeeded(.reassemblerMissing, expectedStreamID: streamID)
            return
        }

        let wirePayload = data.dropFirst(MirageWire.mirageHeaderSize)
        // Local media encryption adds packet-level auth tags on top of the Loom session.
        let expectedWireLength =
            header.flags.contains(.encryptedPayload)
            ? Int(header.payloadLength) + MirageMediaSecurity.authTagLength
            : Int(header.payloadLength)
        guard wirePayload.count == expectedWireLength else {
            logFirstVideoPacketRejectionIfNeeded(.invalidWireLength, expectedStreamID: streamID)
            return
        }

        let payload: Data
        if header.flags.contains(.encryptedPayload) {
            guard let mediaPacketKey = packetContext.mediaPacketKey else {
                logFirstVideoPacketRejectionIfNeeded(.decryptFailure, expectedStreamID: streamID)
                return
            }
            do {
                payload = try MirageMediaSecurity.decryptVideoPayload(
                    wirePayload,
                    header: header,
                    key: mediaPacketKey,
                    direction: .hostToClient
                )
            } catch {
                logFirstVideoPacketRejectionIfNeeded(.decryptFailure, expectedStreamID: streamID)
                return
            }
            guard payload.count == Int(header.payloadLength) else {
                logFirstVideoPacketRejectionIfNeeded(.decryptFailure, expectedStreamID: streamID)
                return
            }
        } else {
            payload = Data(wirePayload)
        }

        reassembler.processPacket(payload, header: header)
    }

    private nonisolated func processIncomingMosaicVideoData(
        _ data: Data,
        header: MirageWire.MirageMosaicPacketHeader,
        expectedStreamID: StreamID
    ) {
        let streamID = header.streamID
        guard streamID == expectedStreamID else {
            logFirstVideoPacketRejectionIfNeeded(
                .streamIDMismatch,
                expectedStreamID: expectedStreamID,
                actualStreamID: streamID
            )
            return
        }

        fastPathState.noteInboundMediaActivity()

        guard let packetContext = fastPathState.videoPacketContext(for: streamID) else {
            if fastPathState.bufferEarlyVideoPacket(data, for: streamID) {
                MirageLogger.client(
                    "Media stream \(streamID) buffered early startup Mosaic video packet bytes=\(data.count)"
                )
            }
            logFirstVideoPacketRejectionIfNeeded(.packetContextMissing, expectedStreamID: streamID)
            return
        }

        if packetContext.consumedStartupPending {
            MirageLogger.client(
                "Media stream \(streamID) consumed startup-pending on first Mosaic packet bytes=\(data.count)"
            )
            Task { @MainActor in
                self.logStartupFirstPacketIfNeeded(streamID: streamID)
                self.cancelStartupRegistrationRetry(streamID: streamID)
            }
        }

        let wirePayload = data.dropFirst(MirageWire.mirageMosaicHeaderSize)
        let expectedWireLength =
            header.flags.contains(.encryptedPayload)
            ? Int(header.payloadLength) + MirageMediaSecurity.authTagLength
            : Int(header.payloadLength)
        guard wirePayload.count == expectedWireLength else {
            logFirstVideoPacketRejectionIfNeeded(.invalidWireLength, expectedStreamID: streamID)
            return
        }

        let payload: Data
        if header.flags.contains(.encryptedPayload) {
            guard let mediaPacketKey = packetContext.mediaPacketKey else {
                logFirstVideoPacketRejectionIfNeeded(.decryptFailure, expectedStreamID: streamID)
                return
            }
            do {
                payload = try MirageMediaSecurity.decryptMosaicVideoPayload(
                    wirePayload,
                    header: header,
                    key: mediaPacketKey,
                    direction: .hostToClient
                )
            } catch {
                logFirstVideoPacketRejectionIfNeeded(.decryptFailure, expectedStreamID: streamID)
                return
            }
            guard payload.count == Int(header.payloadLength) else {
                logFirstVideoPacketRejectionIfNeeded(.decryptFailure, expectedStreamID: streamID)
                return
            }
        } else {
            payload = Data(wirePayload)
        }

        var plaintextHeader = header
        plaintextHeader.flags.remove(.encryptedPayload)
        plaintextHeader.payloadLength = UInt32(payload.count)
        plaintextHeader.checksum = MirageWire.CRC32.calculate(payload)
        let plaintextPacket = plaintextHeader.serialize() + payload
        guard let completedUnit = packetContext.mosaicReassembler.processPacket(plaintextPacket) else {
            return
        }
        processCompletedMosaicUnit(
            completedUnit,
            packetContext: packetContext,
            streamID: streamID,
            allowBuffering: true
        )
    }

    nonisolated func processBufferedMosaicUnitsIfNeeded(streamID: StreamID) {
        let units = fastPathState.takeBufferedMosaicUnits(for: streamID)
        guard !units.isEmpty,
              let packetContext = fastPathState.videoPacketContext(for: streamID) else {
            return
        }
        for unit in units {
            processCompletedMosaicUnit(
                unit,
                packetContext: packetContext,
                streamID: streamID,
                allowBuffering: false
            )
        }
    }

    private nonisolated func processCompletedMosaicUnit(
        _ completedUnit: StreamControllerMosaicMediaUnitReassembler.CompletedUnit,
        packetContext: MirageClientFastPathState.VideoPacketContext,
        streamID: StreamID,
        allowBuffering: Bool
    ) {
        if let mosaicTilePlan = packetContext.mosaicTilePlan,
           mosaicTilePlan.epoch == completedUnit.tilePlanEpoch {
            Task {
                let result = await packetContext.mosaicPipeline.process(
                    completedUnit,
                    plan: mosaicTilePlan
                )
                guard result == .submitted else { return }
                await MainActor.run {
                    self.sessionStore.markFirstFrameDecoded(for: streamID)
                }
            }
            return
        }

        guard allowBuffering,
              Self.shouldBufferMosaicUnit(
                completedUnit,
                currentPlan: packetContext.mosaicTilePlan
              ),
              fastPathState.bufferMosaicUnit(completedUnit, for: streamID) else {
            return
        }
        MirageLogger.client(
            "Media stream \(streamID) buffered Mosaic media unit pending tile plan " +
                "epoch=\(completedUnit.tilePlanEpoch) unit=\(completedUnit.mediaUnitIndex)"
        )
    }

    private nonisolated static func shouldBufferMosaicUnit(
        _ completedUnit: StreamControllerMosaicMediaUnitReassembler.CompletedUnit,
        currentPlan: MirageMedia.MirageMosaicTilePlan?
    ) -> Bool {
        guard let currentPlan else { return true }
        return completedUnit.tilePlanEpoch > currentPlan.epoch
    }

    func handleMosaicRecoveryRequest(
        streamID: StreamID,
        trigger: StreamControllerMosaicClientPipeline.RecoveryTrigger
    ) async {
        guard let controller = controllersByStream[streamID] else { return }
        let reason = Self.streamRecoveryReason(forMosaicTrigger: trigger)
        MirageLogger.client(
            "Mosaic recovery requested for stream \(streamID) trigger=\(trigger.rawValue)"
        )
        await controller.requestKeyframeRecoveryIfPossible(reason: reason)
    }

    nonisolated static func streamRecoveryReason(
        forMosaicTrigger trigger: StreamControllerMosaicClientPipeline.RecoveryTrigger
    ) -> StreamController.RecoveryReason {
        switch trigger {
        case .decodeErrorThreshold,
             .dependencyMissing,
             .dependencyMismatch,
             .decodeSubmissionFailure:
            .decodeErrorThreshold
        }
    }

    private nonisolated func logFirstVideoPacketRejectionIfNeeded(
        _ reason: IncomingVideoPacketRejectionReason,
        expectedStreamID: StreamID,
        actualStreamID: StreamID? = nil
    ) {
        guard fastPathState.markFirstVideoPacketRejectionReason(reason, for: expectedStreamID) else {
            return
        }

        if let actualStreamID {
            MirageLogger.client(
                "Media stream \(expectedStreamID) rejected first startup video packet reason=\(reason.rawValue) actualStream=\(actualStreamID)"
            )
        } else {
            MirageLogger.client(
                "Media stream \(expectedStreamID) rejected first startup video packet reason=\(reason.rawValue)"
            )
        }
    }

    func logStartupFirstPacketIfNeeded(streamID: StreamID) {
        guard let baseTime = streamStartupBaseTimes[streamID],
              !streamStartupFirstPacketReceived.contains(streamID) else {
            return
        }
        streamStartupFirstPacketReceived.insert(streamID)
        let deltaMs = Int((CFAbsoluteTimeGetCurrent() - baseTime) * 1000)
        MirageLogger.signpostEvent(
            .client, "Startup.FirstVideoPacketReceived", "stream=\(streamID)"
        )
        MirageLogger.client(
            "Desktop start: first video packet received for stream \(streamID) (+\(deltaMs)ms)"
        )
    }

    func processBufferedEarlyVideoPacketIfNeeded(streamID: StreamID) {
        guard let data = fastPathState.takeBufferedEarlyVideoPacket(for: streamID) else { return }
        MirageLogger.client(
            "Media stream \(streamID) processing buffered early startup video packet bytes=\(data.count)"
        )
        processIncomingVideoData(data, expectedStreamID: streamID)
    }

    /// Stop the video stream receive task for a specific stream.
    func stopVideoStreamReceive(for streamID: StreamID) {
        let streamKey = "video/\(streamID)"
        let hadActiveStream = videoStreamReceiveTasks[streamID] != nil ||
            videoPacketIngressProcessors[streamID] != nil ||
            activeMediaStreams[streamKey] != nil
        videoStreamReceiveTasks[streamID]?.cancel()
        videoStreamReceiveTasks.removeValue(forKey: streamID)
        activeMediaStreams[streamKey]?.clearIncomingBytesBatchHandler()
        videoPacketIngressProcessors.removeValue(forKey: streamID)?.finish()
        videoIngressTelemetryStore.clear(streamID: streamID)
        videoIngressLastDropCountByStream.removeValue(forKey: streamID)
        activeMediaStreams.removeValue(forKey: streamKey)
        fastPathState.clearBufferedEarlyVideoPacket(for: streamID)
        fastPathState.clearBufferedMosaicUnits(for: streamID)
        refreshActiveStreamTransportBudgetPolicy()
        cancelForegroundRecoveryMonitor(for: streamID)
        clearReceiverMediaFeedbackState(for: streamID)
        if hadActiveStream {
            MirageLogger.client(
                "event=stream_boundary phase=end side=client media=video stream=\(streamID)"
            )
        }
    }

    private func handleObservedIncomingMediaStream(
        _ stream: any MirageIncomingMediaStream,
        label: String,
        sessionID: UUID
    ) async {
        if fastPathState.markObservedMediaStreamLabel(label) {
            MirageLogger.client(
                "Observed incoming Loom media stream label=\(label) session=\(sessionID.uuidString)"
            )
        }

        switch IncomingMediaStreamKind.classify(label: label) {
        case let .video(streamID):
            MirageLogger.client(
                "event=stream_boundary phase=start side=client media=video " +
                    "stream=\(streamID) label=\(label) session=\(sessionID.uuidString)"
            )
            activeMediaStreams[label] = stream
            refreshActiveStreamTransportBudgetPolicy()
            startVideoStreamReceiveLoop(stream: stream, streamID: streamID)

        case let .audio(streamID):
            MirageLogger.client(
                "event=stream_boundary phase=start side=client media=audio " +
                    "stream=\(streamID) label=\(label) session=\(sessionID.uuidString)"
            )
            activeMediaStreams[label] = stream
            await startAudioStreamReceiveLoop(stream: stream, streamID: streamID)

        case .transferData:
            break

        case .unknown:
            MirageLogger.client("Ignoring incoming Loom stream with unknown label: \(label)")
        }
    }

    private func finishVideoStreamReceiveLoop(streamID: StreamID) async {
        let streamKey = "video/\(streamID)"
        let hadActiveStream = videoStreamReceiveTasks[streamID] != nil ||
            videoPacketIngressProcessors[streamID] != nil ||
            activeMediaStreams[streamKey] != nil
        videoStreamReceiveTasks.removeValue(forKey: streamID)
        activeMediaStreams[streamKey]?.clearIncomingBytesBatchHandler()
        videoPacketIngressProcessors.removeValue(forKey: streamID)?.finish()
        videoIngressTelemetryStore.clear(streamID: streamID)
        videoIngressLastDropCountByStream.removeValue(forKey: streamID)
        activeMediaStreams.removeValue(forKey: streamKey)
        fastPathState.clearBufferedEarlyVideoPacket(for: streamID)
        fastPathState.clearBufferedMosaicUnits(for: streamID)
        refreshActiveStreamTransportBudgetPolicy()
        if hadActiveStream {
            MirageLogger.client(
                "event=stream_boundary phase=end side=client media=video stream=\(streamID)"
            )
        }
        if shouldForceLocalTeardownForUnreferencedVideoStream(streamID: streamID) {
            MirageLogger.client(
                "Video stream receive loop ended for unreferenced stream \(streamID); forcing local teardown"
            )
            await forceStopAppAtlasMediaStreamLocally(mediaStreamID: streamID)
            return
        }
        MirageLogger.client("Video stream receive loop ended for stream \(streamID)")
    }

    func shouldForceLocalTeardownForUnreferencedVideoStream(streamID: StreamID) -> Bool {
        let hasReferencedSession = desktopStreamID == streamID ||
            activeStreams.contains { $0.id == streamID || $0.mediaStreamID == streamID } ||
            sessionStore.activeSessions.contains { $0.streamID == streamID || $0.mediaStreamID == streamID }
        guard !hasReferencedSession else { return false }
        return controllersByStream[streamID] != nil ||
            registeredStreamIDs.contains(streamID) ||
            metricsStore.snapshot(for: streamID) != nil
    }

    // MARK: - Keyframe Requests

    /// Request a keyframe from the host when decoder encounters errors.
    @discardableResult
    func sendKeyframeRequest(for streamID: StreamID) -> Bool {
        guard case .connected = connectionState else {
            MirageLogger.client("Cannot send keyframe request - not connected")
            return false
        }

        let now = CFAbsoluteTimeGetCurrent()
        if !Self.shouldSendKeyframeRequest(
            lastRequestTime: lastKeyframeRequestTime[streamID],
            now: now,
            cooldown: keyframeRequestCooldown
        ) {
            let lastTime = lastKeyframeRequestTime[streamID] ?? now
            let remaining = Int(((keyframeRequestCooldown - (now - lastTime)) * 1000).rounded())
            let cooldownMs = Int((keyframeRequestCooldown * 1000).rounded())
            MirageLogger
                .client(
                    "Keyframe request skipped (cooldown \(remaining)ms remaining of \(cooldownMs)ms) for stream \(streamID)"
                )
            return false
        }

        let recoveryCause = sessionStore.sessionByStreamID(streamID)?.clientRecoveryCause ??
            sessionStore.sessionByMediaStreamID(streamID)?.clientRecoveryCause ??
            .none
        let mediaRecoveryCause = MirageWire.MirageMediaFeedbackRecoveryCause(recoveryCause)
        let request = MirageWire.KeyframeRequestMessage(
            streamID: streamID,
            recoveryCause: mediaRecoveryCause
        )
        guard let message = try? MirageWire.ControlMessage(type: .keyframeRequest, content: request) else {
            MirageLogger.error(.client, "Failed to create keyframe request message")
            return false
        }
        guard sendControlMessageBestEffort(message) else {
            MirageLogger.client("Cannot send keyframe request - control channel unavailable")
            return false
        }
        _ = sendControlMessageBestEffortUnreliable(message)
        lastKeyframeRequestTime[streamID] = now

        let cooldownMs = Int((keyframeRequestCooldown * 1000).rounded())
        MirageLogger.client(
            "Sent keyframe request for stream \(streamID) cause=\(mediaRecoveryCause.rawValue) (cooldown \(cooldownMs)ms)"
        )
        return true
    }

    func handleKeyframeRecoveryAck(_ message: MirageWire.ControlMessage) {
        let ack: MirageWire.KeyframeRecoveryAckMessage
        do {
            ack = try message.decode(MirageWire.KeyframeRecoveryAckMessage.self)
        } catch {
            MirageLogger.error(
                .client, error: error, message: "Failed to decode keyframe recovery ack: "
            )
            return
        }
        guard let controller = controllersByStream[ack.streamID] else { return }
        if ack.state == .noStream,
           shouldForceLocalTeardownForUnreferencedVideoStream(streamID: ack.streamID) {
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard shouldForceLocalTeardownForUnreferencedVideoStream(streamID: ack.streamID) else {
                    return
                }
                MirageLogger.client(
                    "Keyframe recovery ack reported no host stream for unreferenced media \(ack.streamID); forcing local teardown"
                )
                await forceStopAppAtlasMediaStreamLocally(mediaStreamID: ack.streamID)
            }
            return
        }
        Task {
            await controller.handleKeyframeRecoveryAck(ack)
        }
    }

    private nonisolated static func shouldSendKeyframeRequest(
        lastRequestTime: CFAbsoluteTime?,
        now: CFAbsoluteTime,
        cooldown: CFAbsoluteTime
    ) -> Bool {
        guard let lastRequestTime else { return true }
        return now - lastRequestTime >= cooldown
    }
}

private extension MirageWire.MirageMediaFeedbackRecoveryCause {
    init(_ cause: MirageStreamClientRecoveryCause) {
        self = switch cause {
        case .none:
            .none
        case .decodeError:
            .decodeError
        case .frameLoss:
            .frameLoss
        case .freezeTimeout:
            .freezeTimeout
        case .memoryBudget:
            .memoryBudget
        case .startupTimeout:
            .startupTimeout
        case .manual:
            .manual
        }
    }
}
