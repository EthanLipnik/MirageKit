//
//  MirageClientService+Video.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Loom stream video transport and keyframe recovery.
//

import Foundation
import Loom
import Network
import MirageKit

private enum MirageClientStreamRecoveryTrigger: Sendable {
    case manual
    case applicationActivation
    case decoderCompatibilityFallback

    var logLabel: String {
        switch self {
        case .manual:
            "manual"
        case .applicationActivation:
            "application-activation"
        case .decoderCompatibilityFallback:
            "decoder-compatibility-fallback"
        }
    }

    var awaitFirstPresentedFrame: Bool {
        switch self {
        case .manual:
            false
        case .applicationActivation,
             .decoderCompatibilityFallback:
            true
        }
    }

    var firstPresentedFrameWaitReason: String? {
        switch self {
        case .manual:
            nil
        case .applicationActivation:
            "application-activation-recovery"
        case .decoderCompatibilityFallback:
            "decoder-compatibility-recovery"
        }
    }
}

enum IncomingMediaStreamKind: Equatable {
    case video(StreamID)
    case audio(StreamID)
    case qualityTest(UUID)
    case transferControl
    case transferData
    case unknown

    static func classify(label: String) -> IncomingMediaStreamKind {
        if label == "loom.transfer.control.v1" {
            return .transferControl
        }

        if label.hasPrefix("loom.transfer.data.") {
            return .transferData
        }

        if label.hasPrefix("video/") {
            let streamIDString = String(label.dropFirst("video/".count))
            guard let streamID = StreamID(streamIDString) else { return .unknown }
            return .video(streamID)
        }

        if label.hasPrefix("audio/") {
            let streamIDString = String(label.dropFirst("audio/".count))
            guard let streamID = StreamID(streamIDString) else { return .unknown }
            return .audio(streamID)
        }

        if label.hasPrefix("quality-test/") {
            let testIDString = String(label.dropFirst("quality-test/".count))
            guard let testID = UUID(uuidString: testIDString) else { return .unknown }
            return .qualityTest(testID)
        }

        return .unknown
    }
}

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
                guard await service.isCurrentLoomSession(sessionID: session.id) else { break }
                guard let label = stream.label else {
                    MirageLogger.client("Ignoring incoming Loom stream with no label (id=\(stream.id))")
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
        for task in videoStreamReceiveTasks.values {
            task.cancel()
        }
        videoStreamReceiveTasks.removeAll()
        audioStreamReceiveTask?.cancel()
        audioStreamReceiveTask = nil
        for task in qualityTestStreamReceiveTasks.values {
            task.cancel()
        }
        qualityTestStreamReceiveTasks.removeAll()
        activeMediaStreams.removeAll()
    }

    // MARK: - Video Stream Receive

    /// Start receiving video packets from a Loom multiplexed stream.
    private func startVideoStreamReceiveLoop(stream: LoomMultiplexedStream, streamID: StreamID) {
        videoStreamReceiveTasks[streamID]?.cancel()
        let serviceBox = WeakSendableBox(self)
        videoStreamReceiveTasks[streamID] = Task.detached(priority: .userInitiated) { [stream, streamID, serviceBox] in
            for await data in stream.incomingBytes {
                guard !Task.isCancelled else { break }
                serviceBox.value?.handleIncomingVideoData(data, expectedStreamID: streamID)
            }
            guard let service = serviceBox.value else { return }
            await service.finishVideoStreamReceiveLoop(streamID: streamID)
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
            await service.finishQualityTestStreamReceiveLoop(testID: testID, label: label)
        }
    }

    /// Process a single video packet received from a Loom stream.
    private nonisolated func handleIncomingVideoData(_ data: Data, expectedStreamID: StreamID) {
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

        guard let packetContext = fastPathState.videoPacketContext(for: streamID) else {
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
        // Loom session handles encryption, so packets arrive unencrypted.
        // Accept both encrypted and unencrypted payloads for backward compatibility.
        let expectedWireLength = header.flags.contains(.encryptedPayload)
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
        MirageLogger.signpostEvent(.client, "Startup.FirstVideoPacketReceived", "stream=\(streamID)")
        MirageLogger.client("Desktop start: first video packet received for stream \(streamID) (+\(deltaMs)ms)")
    }

    /// Stop the video stream receive task for a specific stream.
    func stopVideoStreamReceive(for streamID: StreamID) {
        videoStreamReceiveTasks[streamID]?.cancel()
        videoStreamReceiveTasks.removeValue(forKey: streamID)
        activeMediaStreams.removeValue(forKey: "video/\(streamID)")
        cancelRecoveryKeyframeRetry(for: streamID)
    }

    func isCurrentLoomSession(sessionID: UUID) -> Bool {
        loomSession?.id == sessionID
    }

    private func handleObservedIncomingMediaStream(
        _ stream: LoomMultiplexedStream,
        label: String,
        sessionID: UUID
    ) {
        if fastPathState.markObservedMediaStreamLabel(label) {
            MirageLogger.client(
                "Observed incoming Loom media stream label=\(label) session=\(sessionID.uuidString)"
            )
        }

        switch IncomingMediaStreamKind.classify(label: label) {
        case .video(let streamID):
            MirageLogger.client("Accepted incoming video stream for stream \(streamID)")
            activeMediaStreams[label] = stream
            startVideoStreamReceiveLoop(stream: stream, streamID: streamID)

        case .audio(let streamID):
            MirageLogger.client("Accepted incoming audio stream for stream \(streamID)")
            activeMediaStreams[label] = stream
            startAudioStreamReceiveLoop(stream: stream, streamID: streamID)

        case .qualityTest(let testID):
            MirageLogger.client("Accepted incoming quality-test stream for test \(testID.uuidString)")
            activeMediaStreams[label] = stream
            startQualityTestStreamReceiveLoop(stream: stream, testID: testID, label: label)

        case .transferControl, .transferData:
            break

        case .unknown:
            MirageLogger.client("Ignoring incoming Loom stream with unknown label: \(label)")
        }
    }

    private func finishVideoStreamReceiveLoop(streamID: StreamID) {
        videoStreamReceiveTasks.removeValue(forKey: streamID)
        activeMediaStreams.removeValue(forKey: "video/\(streamID)")
        MirageLogger.client("Video stream receive loop ended for stream \(streamID)")
    }

    private func finishQualityTestStreamReceiveLoop(testID: UUID, label: String) {
        qualityTestStreamReceiveTasks.removeValue(forKey: testID)
        activeMediaStreams.removeValue(forKey: label)
        MirageLogger.client("Quality-test stream receive loop ended for test \(testID.uuidString)")
    }

    // MARK: - Control Path Handling

    func handleControlPathUpdate(_ snapshot: MirageNetworkPathSnapshot) {
        let previous = controlPathSnapshot
        controlPathSnapshot = snapshot
        guard awdlExperimentEnabled else { return }
        guard let previous, previous.signature != snapshot.signature else { return }
        if previous.kind != snapshot.kind {
            awdlPathSwitches &+= 1
            MirageLogger.client(
                "Control path switch \(previous.kind.rawValue) -> \(snapshot.kind.rawValue) (count \(awdlPathSwitches))"
            )
        }
    }

    func logAwdlExperimentTelemetryIfNeeded() {
        guard awdlExperimentEnabled else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard lastAwdlTelemetryLogTime == 0 || now - lastAwdlTelemetryLogTime >= 5.0 else { return }
        lastAwdlTelemetryLogTime = now
        MirageLogger.metrics(
            "AWDL telemetry: stalls=\(stallEvents), pathSwitches=\(awdlPathSwitches), registrationRefresh=\(registrationRefreshCount), hostRefreshReq=\(transportRefreshRequests), activeJitterHoldMs=\(activeJitterHoldMs)"
        )
    }

    // MARK: - Keyframe Requests

    /// Request a keyframe from the host when decoder encounters errors.
    func sendKeyframeRequest(for streamID: StreamID) {
        guard case .connected = connectionState else {
            MirageLogger.client("Cannot send keyframe request - not connected")
            return
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
            return
        }
        lastKeyframeRequestTime[streamID] = now

        let request = KeyframeRequestMessage(streamID: streamID)
        guard let message = try? ControlMessage(type: .keyframeRequest, content: request) else {
            MirageLogger.error(.client, "Failed to create keyframe request message")
            return
        }

        sendControlMessageBestEffort(message)
        let cooldownMs = Int((keyframeRequestCooldown * 1000).rounded())
        MirageLogger.client("Sent keyframe request for stream \(streamID) (cooldown \(cooldownMs)ms)")
    }

    nonisolated static func shouldSendKeyframeRequest(
        lastRequestTime: CFAbsoluteTime?,
        now: CFAbsoluteTime,
        cooldown: CFAbsoluteTime
    ) -> Bool {
        guard let lastRequestTime else { return true }
        return now - lastRequestTime >= cooldown
    }

    // MARK: - Stream Recovery

    /// Request stream recovery by forcing a keyframe.
    public func requestStreamRecovery(for streamID: StreamID) {
        requestStreamRecovery(for: streamID, trigger: .manual)
    }

    func requestApplicationActivationRecovery(for streamID: StreamID) {
        requestStreamRecovery(for: streamID, trigger: .applicationActivation)
    }

    private func requestStreamRecovery(
        for streamID: StreamID,
        trigger: MirageClientStreamRecoveryTrigger
    ) {
        guard case .connected = connectionState else {
            MirageLogger.client("Stream recovery skipped (\(trigger.logLabel)) - not connected")
            return
        }
        guard let controller = controllersByStream[streamID] else {
            MirageLogger.client(
                "Stream recovery skipped (\(trigger.logLabel)) - stream \(streamID) is no longer active"
            )
            return
        }

        MirageLogger.client("Stream recovery requested for stream \(streamID) trigger=\(trigger.logLabel)")

        MirageFrameCache.shared.clear(for: streamID)
        cancelRecoveryKeyframeRetry(for: streamID)
        if trigger.awaitFirstPresentedFrame {
            startRecoveryKeyframeRetry(for: streamID, controller: controller, trigger: trigger)
        }

        Task { [weak self] in
            guard let self else { return }
            await controller.requestRecovery(
                reason: .manualRecovery,
                awaitFirstPresentedFrame: trigger.awaitFirstPresentedFrame,
                firstPresentedFrameWaitReason: trigger.firstPresentedFrameWaitReason
            )
            self.sendKeyframeRequest(for: streamID)
        }
    }

    private func startRecoveryKeyframeRetry(
        for streamID: StreamID,
        controller: StreamController,
        trigger: MirageClientStreamRecoveryTrigger
    ) {
        let token = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finishRecoveryKeyframeRetry(for: streamID, token: token) }

            let reassembler = await controller.getReassembler()
            var lastPacketTime = reassembler.latestPacketReceivedTime()

            for attempt in 1...self.recoveryKeyframeRetryLimit {
                do {
                    try await Task.sleep(for: self.recoveryKeyframeRetryInterval)
                } catch {
                    return
                }

                guard case .connected = self.connectionState,
                      self.controllersByStream[streamID] != nil else {
                    return
                }

                let latestPacketTime = reassembler.latestPacketReceivedTime()
                if latestPacketTime > lastPacketTime {
                    MirageLogger.client(
                        "Recovery packet flow resumed for stream \(streamID); ending retry loop trigger=\(trigger.logLabel)"
                    )
                    return
                }

                MirageLogger.client(
                    "Recovery packet flow stalled for stream \(streamID); retrying keyframe (\(attempt)/\(self.recoveryKeyframeRetryLimit)) trigger=\(trigger.logLabel)"
                )
                self.sendKeyframeRequest(for: streamID)
                lastPacketTime = latestPacketTime
            }
        }

        recoveryKeyframeRetryTasks[streamID] = (token: token, task: task)
    }

    func cancelRecoveryKeyframeRetry(for streamID: StreamID) {
        guard let retry = recoveryKeyframeRetryTasks.removeValue(forKey: streamID) else { return }
        retry.task.cancel()
    }

    private func cancelRecoveryKeyframeRetries() {
        let retries = recoveryKeyframeRetryTasks.values
        recoveryKeyframeRetryTasks.removeAll()
        for retry in retries {
            retry.task.cancel()
        }
    }

    private func finishRecoveryKeyframeRetry(for streamID: StreamID, token: UUID) {
        guard recoveryKeyframeRetryTasks[streamID]?.token == token else { return }
        recoveryKeyframeRetryTasks.removeValue(forKey: streamID)
    }

    // MARK: - Encoder Settings

    public func sendStreamEncoderSettingsChange(
        streamID: StreamID,
        colorDepth: MirageStreamColorDepth? = nil,
        bitrate: Int? = nil,
        streamScale: CGFloat? = nil
    )
    async throws {
        guard case .connected = connectionState else { throw MirageError.protocolError("Not connected") }
        guard colorDepth != nil || bitrate != nil || streamScale != nil else { return }

        let clampedScale = streamScale.map(clampStreamScale)
        let request = StreamEncoderSettingsChangeMessage(
            streamID: streamID,
            colorDepth: colorDepth,
            bitrate: bitrate,
            streamScale: clampedScale
        )
        try await sendControlMessage(.streamEncoderSettingsChange, content: request)
    }

    // MARK: - Adaptive Fallback

    func handleAdaptiveFallbackTrigger(for streamID: StreamID) {
        let resolvedBitDepth = resolvedDecoderBitDepth(for: streamID)
        let now = CFAbsoluteTimeGetCurrent()
        if Self.shouldApplyDecoderCompatibilityFallback(
            mode: adaptiveFallbackMode,
            resolvedBitDepth: resolvedBitDepth,
            lastAppliedTime: decoderCompatibilityFallbackLastAppliedTime[streamID],
            now: now,
            cooldown: decoderCompatibilityFallbackCooldown
        ) {
            applyDecoderCompatibilityFallback(for: streamID, at: now)
            return
        }
        if adaptiveFallbackMode == .disabled, resolvedBitDepth == .tenBit {
            let lastApplied = decoderCompatibilityFallbackLastAppliedTime[streamID] ?? now
            let remainingMs = Int(((decoderCompatibilityFallbackCooldown - (now - lastApplied)) * 1000).rounded(.up))
            MirageLogger.client(
                "Decoder compatibility fallback cooldown \(max(0, remainingMs))ms for stream \(streamID)"
            )
            return
        }

        switch adaptiveFallbackMode {
        case .disabled:
            MirageLogger.client("Adaptive fallback skipped (mode disabled) for stream \(streamID)")
        case .adaptive:
            MirageLogger.client("Adaptive receiver-health recovery is app-owned for stream \(streamID)")
        }
    }

    nonisolated static func shouldApplyDecoderCompatibilityFallback(
        mode: AdaptiveFallbackMode,
        resolvedBitDepth: MirageVideoBitDepth,
        lastAppliedTime: CFAbsoluteTime?,
        now: CFAbsoluteTime,
        cooldown: CFAbsoluteTime
    )
    -> Bool {
        guard mode == .disabled else { return false }
        guard resolvedBitDepth == .tenBit else { return false }
        guard let lastAppliedTime, lastAppliedTime > 0 else { return true }
        return now - lastAppliedTime >= cooldown
    }

    private func applyDecoderCompatibilityFallback(for streamID: StreamID, at now: CFAbsoluteTime) {
        // ProRes uses fixed quality — do not apply decoder compatibility fallback
        if activeStreamCodecs[streamID] == .proRes4444 {
            MirageLogger.client("Skipping decoder compatibility fallback for ProRes stream \(streamID)")
            return
        }

        decoderCompatibilityFallbackLastAppliedTime[streamID] = now
        Task { [weak self] in
            guard let self else { return }
            do {
                try await sendStreamEncoderSettingsChange(
                    streamID: streamID,
                    colorDepth: .standard
                )
                decoderCompatibilityCurrentColorDepthByStream[streamID] = .standard
                if let controller = controllersByStream[streamID] {
                    await controller.setPreferredDecoderColorDepth(.standard)
                }
                MirageLogger.client(
                    "Decoder compatibility fallback forced color depth Pro/Ultra -> Standard for stream \(streamID)"
                )
                requestStreamRecovery(for: streamID, trigger: .decoderCompatibilityFallback)
            } catch {
                decoderCompatibilityFallbackLastAppliedTime.removeValue(forKey: streamID)
                MirageLogger.error(
                    .client,
                    error: error,
                    message: "Failed to apply decoder compatibility fallback for stream \(streamID): "
                )
            }
        }
    }

    func configureDecoderColorDepthBaseline(
        for streamID: StreamID,
        colorDepth: MirageStreamColorDepth?
    ) {
        if let colorDepth {
            decoderCompatibilityCurrentColorDepthByStream[streamID] = colorDepth
            decoderCompatibilityBaselineColorDepthByStream[streamID] = colorDepth
        } else {
            decoderCompatibilityCurrentColorDepthByStream.removeValue(forKey: streamID)
            decoderCompatibilityBaselineColorDepthByStream.removeValue(forKey: streamID)
        }
        decoderCompatibilityFallbackLastAppliedTime[streamID] = 0
    }

    func clearDecoderColorDepthState(for streamID: StreamID) {
        decoderCompatibilityCurrentColorDepthByStream.removeValue(forKey: streamID)
        decoderCompatibilityBaselineColorDepthByStream.removeValue(forKey: streamID)
        decoderCompatibilityFallbackLastAppliedTime.removeValue(forKey: streamID)
    }

    func handleVideoPacket(_ data: Data, header: FrameHeader) async {
        delegate?.clientService(self, didReceiveVideoPacket: data, forStream: header.streamID)
    }

    // MARK: - Network Endpoint Utilities

    nonisolated static func host(from endpoint: NWEndpoint?) -> NWEndpoint.Host? {
        guard let endpoint else { return nil }
        if case let .hostPort(host, _) = endpoint {
            return host
        }
        return nil
    }

    nonisolated static func serviceName(from endpoint: NWEndpoint?) -> String? {
        guard let endpoint else { return nil }
        if case let .service(name, _, _, _) = endpoint {
            return name
        }
        return nil
    }

    nonisolated static func expandedBonjourHosts(for host: NWEndpoint.Host) -> [NWEndpoint.Host] {
        if let localQualified = localQualifiedBonjourHost(for: host) {
            return [localQualified]
        }
        return [host]
    }

    nonisolated static func localQualifiedBonjourHost(for host: NWEndpoint.Host) -> NWEndpoint.Host? {
        let rawValue = String(describing: host).trimmingCharacters(in: .whitespacesAndNewlines)
        guard shouldQualifyBonjourHostWithLocalDomain(rawValue) else { return nil }
        return NWEndpoint.Host("\(rawValue).local")
    }

    nonisolated static func shouldQualifyBonjourHostWithLocalDomain(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        guard !value.contains("."), !value.contains(":"), !value.contains("%") else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
