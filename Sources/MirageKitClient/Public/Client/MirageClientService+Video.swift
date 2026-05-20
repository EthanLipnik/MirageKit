//
//  MirageClientService+Video.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Loom media stream receive loops.
//

import Foundation
import Loom
import MirageKit
import Network

@MainActor
extension MirageClientService {
    // MARK: - Loom Media Stream Listener

    /// Start listening for incoming media streams on the authenticated Loom session.
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
        cancelRecoveryKeyframeRetries()
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
        for task in qualityTestStreamReceiveTasks.values {
            task.cancel()
        }
        qualityTestStreamReceiveTasks.removeAll()
        activeMediaStreams.removeAll()
        refreshActiveStreamTransportBudgetPolicy()
    }

    // MARK: - Video Stream Receive

    /// Start receiving video packets from a Loom multiplexed stream.
    private func startVideoStreamReceiveLoop(stream: LoomMultiplexedStream, streamID: StreamID) {
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

    private func startQualityTestStreamReceiveLoop(
        stream: LoomMultiplexedStream,
        testID: UUID,
        label: String
    ) {
        qualityTestStreamReceiveTasks[testID]?.cancel()
        let serviceBox = WeakSendableBox(self)
        qualityTestStreamReceiveTasks[testID] = Task.detached(priority: .userInitiated) {
            [stream, testID, label, serviceBox] in
            for await data in stream.incomingBytes {
                guard !Task.isCancelled else { break }
                serviceBox.value?.handleIncomingQualityTestData(data, expectedTestID: testID)
            }
            guard let service = serviceBox.value else { return }
            await MainActor.run {
                service.qualityTestStreamReceiveTasks.removeValue(forKey: testID)
                service.activeMediaStreams.removeValue(forKey: label)
                MirageLogger.client("Quality-test stream receive loop ended for test \(testID.uuidString)")
            }
        }
    }

    /// Process a single video packet received from a Loom stream.
    nonisolated func processIncomingVideoData(_ data: Data, expectedStreamID: StreamID) {
        guard data.count >= mirageHeaderSize, let header = FrameHeader.deserialize(from: data) else {
            return
        }

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

        let wirePayload = data.dropFirst(mirageHeaderSize)
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

    private nonisolated func handleIncomingQualityTestData(_ data: Data, expectedTestID: UUID) {
        guard data.count >= mirageQualityTestHeaderSize,
              let header = QualityTestPacketHeader.deserialize(from: data),
              header.testID == expectedTestID else {
            return
        }

        handleQualityTestPacket(header, data: data)
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
        videoStreamReceiveTasks[streamID]?.cancel()
        videoStreamReceiveTasks.removeValue(forKey: streamID)
        activeMediaStreams["video/\(streamID)"]?.clearIncomingBytesBatchHandler()
        videoPacketIngressProcessors.removeValue(forKey: streamID)?.finish()
        videoIngressTelemetryStore.clear(streamID: streamID)
        videoIngressLastDropCountByStream.removeValue(forKey: streamID)
        activeMediaStreams.removeValue(forKey: "video/\(streamID)")
        fastPathState.clearBufferedEarlyVideoPacket(for: streamID)
        refreshActiveStreamTransportBudgetPolicy()
        cancelRecoveryKeyframeRetry(for: streamID)
        clearReceiverMediaFeedbackState(for: streamID)
    }

    private func handleObservedIncomingMediaStream(
        _ stream: LoomMultiplexedStream,
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
            MirageLogger.client("Accepted incoming video stream for stream \(streamID)")
            activeMediaStreams[label] = stream
            refreshActiveStreamTransportBudgetPolicy()
            startVideoStreamReceiveLoop(stream: stream, streamID: streamID)

        case let .audio(streamID):
            MirageLogger.client("Accepted incoming audio stream for stream \(streamID)")
            activeMediaStreams[label] = stream
            await startAudioStreamReceiveLoop(stream: stream, streamID: streamID)

        case let .qualityTest(testID):
            MirageLogger.client(
                "Accepted incoming quality-test stream for test \(testID.uuidString)"
            )
            activeMediaStreams[label] = stream
            startQualityTestStreamReceiveLoop(stream: stream, testID: testID, label: label)

        case .transferData:
            break

        case .unknown:
            MirageLogger.client("Ignoring incoming Loom stream with unknown label: \(label)")
        }
    }

    private func finishVideoStreamReceiveLoop(streamID: StreamID) async {
        videoStreamReceiveTasks.removeValue(forKey: streamID)
        activeMediaStreams["video/\(streamID)"]?.clearIncomingBytesBatchHandler()
        videoPacketIngressProcessors.removeValue(forKey: streamID)?.finish()
        videoIngressTelemetryStore.clear(streamID: streamID)
        videoIngressLastDropCountByStream.removeValue(forKey: streamID)
        activeMediaStreams.removeValue(forKey: "video/\(streamID)")
        fastPathState.clearBufferedEarlyVideoPacket(for: streamID)
        refreshActiveStreamTransportBudgetPolicy()
        if shouldForceLocalTeardownAfterVideoReceiveEnded(streamID: streamID) {
            MirageLogger.client(
                "Video stream receive loop ended for unreferenced stream \(streamID); forcing local teardown"
            )
            await forceStopWindowStreamLocally(streamID: streamID)
            return
        }
        MirageLogger.client("Video stream receive loop ended for stream \(streamID)")
    }

    private func shouldForceLocalTeardownAfterVideoReceiveEnded(streamID: StreamID) -> Bool {
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

        let request = KeyframeRequestMessage(streamID: streamID)
        guard sendControlMessageBestEffort(.keyframeRequest, content: request) else {
            MirageLogger.error(.client, "Failed to create keyframe request message")
            return false
        }
        lastKeyframeRequestTime[streamID] = now

        let cooldownMs = Int((keyframeRequestCooldown * 1000).rounded())
        MirageLogger.client(
            "Sent keyframe request for stream \(streamID) (cooldown \(cooldownMs)ms)"
        )
        return true
    }

    func handleKeyframeRecoveryAck(_ message: ControlMessage) {
        let ack: KeyframeRecoveryAckMessage
        do {
            ack = try message.decode(KeyframeRecoveryAckMessage.self)
        } catch {
            MirageLogger.error(
                .client, error: error, message: "Failed to decode keyframe recovery ack: "
            )
            return
        }
        guard let controller = controllersByStream[ack.streamID] else { return }
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
