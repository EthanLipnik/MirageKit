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

@MainActor
extension MirageClientService {
    // MARK: - Loom Media Stream Listener

    /// Start listening for incoming media streams on the authenticated Loom session.
    func startMediaStreamListener() {
        guard let session = loomSession else { return }
        stopMediaStreamListener()

        mediaStreamListenerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let observer = session.makeIncomingStreamObserver()
            for await stream in observer {
                guard self.loomSession?.id == session.id else { break }
                guard let label = stream.label else {
                    MirageLogger.client("Ignoring incoming Loom stream with no label (id=\(stream.id))")
                    continue
                }

                if label.hasPrefix("video/") {
                    let streamIDString = String(label.dropFirst("video/".count))
                    guard let streamID = StreamID(streamIDString) else {
                        MirageLogger.client("Ignoring video stream with invalid ID: \(label)")
                        continue
                    }
                    MirageLogger.client("Accepted incoming video stream for stream \(streamID)")
                    self.activeMediaStreams[label] = stream
                    self.startVideoStreamReceiveLoop(stream: stream, streamID: streamID)
                } else if label.hasPrefix("audio/") {
                    let streamIDString = String(label.dropFirst("audio/".count))
                    guard let streamID = StreamID(streamIDString) else {
                        MirageLogger.client("Ignoring audio stream with invalid ID: \(label)")
                        continue
                    }
                    MirageLogger.client("Accepted incoming audio stream for stream \(streamID)")
                    self.activeMediaStreams[label] = stream
                    self.startAudioStreamReceiveLoop(stream: stream, streamID: streamID)
                } else {
                    MirageLogger.client("Ignoring incoming Loom stream with unknown label: \(label)")
                }
            }
        }
    }

    /// Stop the media stream listener and all active media stream receive loops.
    func stopMediaStreamListener() {
        mediaStreamListenerTask?.cancel()
        mediaStreamListenerTask = nil
        for task in videoStreamReceiveTasks.values {
            task.cancel()
        }
        videoStreamReceiveTasks.removeAll()
        audioStreamReceiveTask?.cancel()
        audioStreamReceiveTask = nil
        activeMediaStreams.removeAll()
    }

    // MARK: - Video Stream Receive

    /// Start receiving video packets from a Loom multiplexed stream.
    private func startVideoStreamReceiveLoop(stream: LoomMultiplexedStream, streamID: StreamID) {
        videoStreamReceiveTasks[streamID]?.cancel()
        let service = self
        videoStreamReceiveTasks[streamID] = Task { [weak service] in
            guard let service else { return }
            for await data in stream.incomingBytes {
                guard !Task.isCancelled else { break }
                service.handleIncomingVideoData(data, expectedStreamID: streamID)
            }
            await MainActor.run {
                service.videoStreamReceiveTasks.removeValue(forKey: streamID)
                service.activeMediaStreams.removeValue(forKey: "video/\(streamID)")
                MirageLogger.client("Video stream receive loop ended for stream \(streamID)")
            }
        }
    }

    /// Process a single video packet received from a Loom stream.
    private nonisolated func handleIncomingVideoData(_ data: Data, expectedStreamID: StreamID) {
        guard data.count >= mirageHeaderSize, let header = FrameHeader.deserialize(from: data) else {
            return
        }

        let streamID = header.streamID
        guard streamID == expectedStreamID else { return }

        guard let packetContext = fastPathState.videoPacketContext(for: streamID) else {
            return
        }

        if packetContext.consumedStartupPending {
            Task { @MainActor in
                self.logStartupFirstPacketIfNeeded(streamID: streamID)
                self.cancelStartupRegistrationRetry(streamID: streamID)
            }
        }

        guard let reassembler = packetContext.reassembler else {
            return
        }

        let wirePayload = data.dropFirst(mirageHeaderSize)
        // Loom session handles encryption, so packets arrive unencrypted.
        // Accept both encrypted and unencrypted payloads for backward compatibility.
        let expectedWireLength = header.flags.contains(.encryptedPayload)
            ? Int(header.payloadLength) + MirageMediaSecurity.authTagLength
            : Int(header.payloadLength)
        guard wirePayload.count == expectedWireLength else {
            return
        }

        let payload: Data
        if header.flags.contains(.encryptedPayload) {
            guard let mediaPacketKey = packetContext.mediaPacketKey else {
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
                return
            }
            guard payload.count == Int(header.payloadLength) else {
                return
            }
        } else {
            payload = Data(wirePayload)
        }

        reassembler.processPacket(payload, header: header)
    }

    func logStartupFirstPacketIfNeeded(streamID: StreamID) {
        guard let baseTime = streamStartupBaseTimes[streamID],
              !streamStartupFirstPacketReceived.contains(streamID) else {
            return
        }
        streamStartupFirstPacketReceived.insert(streamID)
        let deltaMs = Int((CFAbsoluteTimeGetCurrent() - baseTime) * 1000)
        MirageLogger.client("Desktop start: first video packet received for stream \(streamID) (+\(deltaMs)ms)")
    }

    /// Stop the video stream receive task for a specific stream.
    func stopVideoStreamReceive(for streamID: StreamID) {
        videoStreamReceiveTasks[streamID]?.cancel()
        videoStreamReceiveTasks.removeValue(forKey: streamID)
        activeMediaStreams.removeValue(forKey: "video/\(streamID)")
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
            lastAppliedTime: adaptiveFallbackLastAppliedTime[streamID],
            now: now,
            cooldown: adaptiveFallbackCooldown
        ) {
            applyDecoderCompatibilityFallback(for: streamID, at: now)
            return
        }
        if adaptiveFallbackMode == .disabled, resolvedBitDepth == .tenBit {
            let lastApplied = adaptiveFallbackLastAppliedTime[streamID] ?? now
            let remainingMs = Int(((adaptiveFallbackCooldown - (now - lastApplied)) * 1000).rounded(.up))
            MirageLogger.client(
                "Decoder compatibility fallback cooldown \(max(0, remainingMs))ms for stream \(streamID)"
            )
            return
        }
        guard adaptiveFallbackEnabled else {
            MirageLogger.client("Adaptive fallback skipped (disabled) for stream \(streamID)")
            return
        }
        guard adaptiveFallbackMutationsEnabled else {
            MirageLogger.client("Adaptive fallback signal-only mode active (no encoder mutation) for stream \(streamID)")
            return
        }

        switch adaptiveFallbackMode {
        case .disabled:
            MirageLogger.client("Adaptive fallback skipped (mode disabled) for stream \(streamID)")
        case .automatic:
            handleAutomaticAdaptiveFallbackTrigger(for: streamID)
        case .customTemporary:
            handleCustomAdaptiveFallbackTrigger(for: streamID)
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

        adaptiveFallbackLastAppliedTime[streamID] = now
        Task { [weak self] in
            guard let self else { return }
            do {
                try await sendStreamEncoderSettingsChange(
                    streamID: streamID,
                    colorDepth: .standard
                )
                adaptiveFallbackColorDepthByStream[streamID] = .standard
                if let controller = controllersByStream[streamID] {
                    await controller.setPreferredDecoderColorDepth(.standard)
                }
                MirageLogger.client(
                    "Decoder compatibility fallback forced color depth Pro/Ultra -> Standard for stream \(streamID)"
                )
                requestStreamRecovery(for: streamID, trigger: .decoderCompatibilityFallback)
            } catch {
                adaptiveFallbackLastAppliedTime.removeValue(forKey: streamID)
                MirageLogger.error(
                    .client,
                    error: error,
                    message: "Failed to apply decoder compatibility fallback for stream \(streamID): "
                )
            }
        }
    }

    func configureAdaptiveFallbackBaseline(
        for streamID: StreamID,
        bitrate: Int?,
        colorDepth: MirageStreamColorDepth?
    ) {
        if let bitrate, bitrate > 0 {
            adaptiveFallbackBitrateByStream[streamID] = bitrate
            adaptiveFallbackBaselineBitrateByStream[streamID] = bitrate
        } else {
            adaptiveFallbackBitrateByStream.removeValue(forKey: streamID)
            adaptiveFallbackBaselineBitrateByStream.removeValue(forKey: streamID)
        }
        if let colorDepth {
            adaptiveFallbackColorDepthByStream[streamID] = colorDepth
            adaptiveFallbackBaselineColorDepthByStream[streamID] = colorDepth
        } else {
            adaptiveFallbackColorDepthByStream.removeValue(forKey: streamID)
            adaptiveFallbackBaselineColorDepthByStream.removeValue(forKey: streamID)
        }

        adaptiveFallbackCollapseTimestampsByStream[streamID] = []
        adaptiveFallbackPressureCountByStream[streamID] = 0
        adaptiveFallbackLastPressureTriggerTimeByStream.removeValue(forKey: streamID)
        adaptiveFallbackStableSinceByStream.removeValue(forKey: streamID)
        adaptiveFallbackLastRestoreTimeByStream.removeValue(forKey: streamID)
        adaptiveFallbackLastCollapseTimeByStream.removeValue(forKey: streamID)
        adaptiveFallbackLastAppliedTime[streamID] = 0
    }

    func clearAdaptiveFallbackState(for streamID: StreamID) {
        adaptiveFallbackBitrateByStream.removeValue(forKey: streamID)
        adaptiveFallbackBaselineBitrateByStream.removeValue(forKey: streamID)
        adaptiveFallbackColorDepthByStream.removeValue(forKey: streamID)
        adaptiveFallbackBaselineColorDepthByStream.removeValue(forKey: streamID)
        adaptiveFallbackCollapseTimestampsByStream.removeValue(forKey: streamID)
        adaptiveFallbackPressureCountByStream.removeValue(forKey: streamID)
        adaptiveFallbackLastPressureTriggerTimeByStream.removeValue(forKey: streamID)
        adaptiveFallbackStableSinceByStream.removeValue(forKey: streamID)
        adaptiveFallbackLastRestoreTimeByStream.removeValue(forKey: streamID)
        adaptiveFallbackLastCollapseTimeByStream.removeValue(forKey: streamID)
        adaptiveFallbackLastAppliedTime.removeValue(forKey: streamID)
    }

    func updateAdaptiveFallbackPressure(streamID: StreamID, targetFrameRate: Int) {
        guard adaptiveFallbackEnabled, adaptiveFallbackMode == .customTemporary else {
            adaptiveFallbackPressureCountByStream.removeValue(forKey: streamID)
            adaptiveFallbackLastPressureTriggerTimeByStream.removeValue(forKey: streamID)
            return
        }
        guard let snapshot = metricsStore.snapshot(for: streamID), snapshot.hasHostMetrics else { return }

        let targetFPS = Double(max(1, targetFrameRate))
        let hostEncodedFPS = max(0.0, snapshot.hostEncodedFPS)
        let underTargetThreshold = targetFPS * adaptiveFallbackPressureUnderTargetRatio
        guard hostEncodedFPS > 0.0, hostEncodedFPS < underTargetThreshold else {
            adaptiveFallbackPressureCountByStream.removeValue(forKey: streamID)
            return
        }

        let receivedFPS = max(0.0, snapshot.receivedFPS)
        let decodedFPS = max(0.0, snapshot.decodedFPS)
        let transportBound = receivedFPS > hostEncodedFPS + adaptiveFallbackPressureHeadroomFPS
        let decodeBound = decodedFPS > receivedFPS + adaptiveFallbackPressureHeadroomFPS
        guard !transportBound, !decodeBound else {
            adaptiveFallbackPressureCountByStream.removeValue(forKey: streamID)
            return
        }

        let now = CFAbsoluteTimeGetCurrent()
        let lastTrigger = adaptiveFallbackLastPressureTriggerTimeByStream[streamID] ?? 0
        if lastTrigger > 0, now - lastTrigger < adaptiveFallbackPressureTriggerCooldown {
            return
        }

        let nextCount = (adaptiveFallbackPressureCountByStream[streamID] ?? 0) + 1
        adaptiveFallbackPressureCountByStream[streamID] = nextCount
        guard nextCount >= adaptiveFallbackPressureTriggerCount else { return }

        adaptiveFallbackPressureCountByStream[streamID] = 0
        adaptiveFallbackLastPressureTriggerTimeByStream[streamID] = now
        let hostText = hostEncodedFPS.formatted(.number.precision(.fractionLength(1)))
        let targetText = targetFPS.formatted(.number.precision(.fractionLength(1)))
        MirageLogger.client(
            "Adaptive fallback trigger (encode pressure): host \(hostText)fps vs target \(targetText)fps for stream \(streamID)"
        )
        handleAdaptiveFallbackTrigger(for: streamID)
    }

    func updateAdaptiveFallbackRecovery(streamID: StreamID, targetFrameRate: Int) {
        guard adaptiveFallbackMutationsEnabled else { return }
        guard adaptiveFallbackEnabled, adaptiveFallbackMode == .customTemporary else { return }

        let baselineColorDepth = adaptiveFallbackBaselineColorDepthByStream[streamID]
        let currentColorDepth = adaptiveFallbackColorDepthByStream[streamID]
        let baselineBitrate = adaptiveFallbackBaselineBitrateByStream[streamID]
        let currentBitrate = adaptiveFallbackBitrateByStream[streamID]

        let colorDepthDegraded = if let baselineColorDepth, let currentColorDepth {
            currentColorDepth != baselineColorDepth
        } else {
            false
        }
        let bitrateDegraded = if let baselineBitrate, let currentBitrate {
            currentBitrate < baselineBitrate
        } else {
            false
        }
        guard colorDepthDegraded || bitrateDegraded else {
            adaptiveFallbackStableSinceByStream.removeValue(forKey: streamID)
            return
        }

        guard let snapshot = metricsStore.snapshot(for: streamID) else {
            adaptiveFallbackStableSinceByStream.removeValue(forKey: streamID)
            return
        }

        let targetFPS = max(1, targetFrameRate)
        let decodedFPS = max(0, snapshot.decodedFPS)
        let receivedFPS = max(0, snapshot.receivedFPS)
        let effectiveFPS: Double = if decodedFPS > 0, receivedFPS > 0 {
            min(decodedFPS, receivedFPS)
        } else {
            max(decodedFPS, receivedFPS)
        }

        let now = CFAbsoluteTimeGetCurrent()
        let lastCollapse = adaptiveFallbackLastCollapseTimeByStream[streamID] ?? 0
        if lastCollapse > 0, now - lastCollapse < customAdaptiveFallbackRestoreWindow {
            adaptiveFallbackStableSinceByStream.removeValue(forKey: streamID)
            return
        }

        let stabilityThreshold = Double(targetFPS) * 0.90
        guard effectiveFPS >= stabilityThreshold else {
            adaptiveFallbackStableSinceByStream.removeValue(forKey: streamID)
            return
        }

        if adaptiveFallbackStableSinceByStream[streamID] == nil {
            adaptiveFallbackStableSinceByStream[streamID] = now
            return
        }
        let stableSince = adaptiveFallbackStableSinceByStream[streamID] ?? now
        guard now - stableSince >= customAdaptiveFallbackRestoreWindow else { return }

        let lastRestore = adaptiveFallbackLastRestoreTimeByStream[streamID] ?? 0
        guard lastRestore == 0 || now - lastRestore >= customAdaptiveFallbackRestoreWindow else { return }

        if bitrateDegraded,
           let baselineBitrate,
           let currentBitrate {
            let stepped = Int((Double(currentBitrate) * adaptiveRestoreBitrateStep).rounded(.down))
            let nextBitrate = min(baselineBitrate, max(currentBitrate + 1, stepped))
            guard nextBitrate > currentBitrate else { return }

            Task { [weak self] in
                guard let self else { return }
                do {
                    try await sendStreamEncoderSettingsChange(streamID: streamID, bitrate: nextBitrate)
                    adaptiveFallbackBitrateByStream[streamID] = nextBitrate
                    adaptiveFallbackLastAppliedTime[streamID] = CFAbsoluteTimeGetCurrent()
                    adaptiveFallbackLastRestoreTimeByStream[streamID] = CFAbsoluteTimeGetCurrent()
                    adaptiveFallbackStableSinceByStream[streamID] = CFAbsoluteTimeGetCurrent()
                    let fromMbps = (Double(currentBitrate) / 1_000_000.0)
                        .formatted(.number.precision(.fractionLength(1)))
                    let toMbps = (Double(nextBitrate) / 1_000_000.0)
                        .formatted(.number.precision(.fractionLength(1)))
                    MirageLogger.client("Adaptive restore bitrate step \(fromMbps) -> \(toMbps) Mbps for stream \(streamID)")
                } catch {
                    MirageLogger.error(.client, error: error, message: "Failed to restore bitrate for stream \(streamID): ")
                }
            }
            return
        }

        if colorDepthDegraded,
           let baselineColorDepth,
           let currentColorDepth,
           let nextColorDepth = nextCustomRestoreColorDepth(current: currentColorDepth, baseline: baselineColorDepth) {
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await sendStreamEncoderSettingsChange(
                        streamID: streamID,
                        colorDepth: nextColorDepth
                    )
                    adaptiveFallbackColorDepthByStream[streamID] = nextColorDepth
                    if let controller = controllersByStream[streamID] {
                        await controller.setPreferredDecoderColorDepth(nextColorDepth)
                    }
                    adaptiveFallbackLastAppliedTime[streamID] = CFAbsoluteTimeGetCurrent()
                    adaptiveFallbackLastRestoreTimeByStream[streamID] = CFAbsoluteTimeGetCurrent()
                    adaptiveFallbackStableSinceByStream[streamID] = CFAbsoluteTimeGetCurrent()
                    MirageLogger
                        .client(
                            "Adaptive restore color depth step \(currentColorDepth.displayName) -> \(nextColorDepth.displayName) for stream \(streamID)"
                        )
                } catch {
                    MirageLogger.error(.client, error: error, message: "Failed to restore color depth for stream \(streamID): ")
                }
            }
        }
    }

    private func handleAutomaticAdaptiveFallbackTrigger(for streamID: StreamID) {
        let now = CFAbsoluteTimeGetCurrent()
        let lastApplied = adaptiveFallbackLastAppliedTime[streamID] ?? 0
        if lastApplied > 0, now - lastApplied < adaptiveFallbackCooldown {
            let remainingMs = Int(((adaptiveFallbackCooldown - (now - lastApplied)) * 1000).rounded())
            MirageLogger.client("Adaptive fallback cooldown \(remainingMs)ms for stream \(streamID)")
            return
        }

        guard let currentBitrate = adaptiveFallbackBitrateByStream[streamID], currentBitrate > 0 else {
            MirageLogger.client("Adaptive fallback skipped (missing baseline bitrate) for stream \(streamID)")
            return
        }
        guard let nextBitrate = Self.nextAdaptiveFallbackBitrate(
            currentBitrate: currentBitrate,
            step: adaptiveFallbackBitrateStep,
            floor: adaptiveFallbackBitrateFloorBps
        ) else {
            let floorText = Double(adaptiveFallbackBitrateFloorBps / 1_000_000)
                .formatted(.number.precision(.fractionLength(1)))
            MirageLogger.client("Adaptive fallback floor reached (\(floorText) Mbps) for stream \(streamID)")
            return
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                try await sendStreamEncoderSettingsChange(streamID: streamID, bitrate: nextBitrate)
                adaptiveFallbackBitrateByStream[streamID] = nextBitrate
                adaptiveFallbackLastAppliedTime[streamID] = CFAbsoluteTimeGetCurrent()
                let fromMbps = (Double(currentBitrate) / 1_000_000.0)
                    .formatted(.number.precision(.fractionLength(1)))
                let toMbps = (Double(nextBitrate) / 1_000_000.0)
                    .formatted(.number.precision(.fractionLength(1)))
                MirageLogger.client("Adaptive fallback bitrate step \(fromMbps) -> \(toMbps) Mbps for stream \(streamID)")
            } catch {
                MirageLogger.error(.client, error: error, message: "Failed to apply adaptive fallback for stream \(streamID): ")
            }
        }
    }

    private func handleCustomAdaptiveFallbackTrigger(for streamID: StreamID) {
        let now = CFAbsoluteTimeGetCurrent()
        var collapseTimes = adaptiveFallbackCollapseTimestampsByStream[streamID] ?? []
        collapseTimes.append(now)
        collapseTimes.removeAll { now - $0 > customAdaptiveFallbackCollapseWindow }
        adaptiveFallbackCollapseTimestampsByStream[streamID] = collapseTimes
        adaptiveFallbackLastCollapseTimeByStream[streamID] = now
        adaptiveFallbackStableSinceByStream.removeValue(forKey: streamID)

        guard collapseTimes.count >= customAdaptiveFallbackCollapseThreshold else {
            MirageLogger
                .client(
                    "Adaptive fallback collapse observed (\(collapseTimes.count)/\(customAdaptiveFallbackCollapseThreshold)) for stream \(streamID)"
                )
            return
        }

        let lastApplied = adaptiveFallbackLastAppliedTime[streamID] ?? 0
        if lastApplied > 0, now - lastApplied < adaptiveFallbackCooldown {
            let remainingMs = Int(((adaptiveFallbackCooldown - (now - lastApplied)) * 1000).rounded())
            MirageLogger.client("Adaptive fallback cooldown \(remainingMs)ms for stream \(streamID)")
            return
        }

        if let currentColorDepth = adaptiveFallbackColorDepthByStream[streamID],
           let nextColorDepth = nextCustomFallbackColorDepth(currentColorDepth) {
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await sendStreamEncoderSettingsChange(
                        streamID: streamID,
                        colorDepth: nextColorDepth
                    )
                    adaptiveFallbackColorDepthByStream[streamID] = nextColorDepth
                    if let controller = controllersByStream[streamID] {
                        await controller.setPreferredDecoderColorDepth(nextColorDepth)
                    }
                    adaptiveFallbackLastAppliedTime[streamID] = CFAbsoluteTimeGetCurrent()
                    let currentName = currentColorDepth.displayName
                    let nextName = nextColorDepth.displayName
                    MirageLogger.client("Adaptive fallback color depth step \(currentName) -> \(nextName) for stream \(streamID)")
                } catch {
                    MirageLogger.error(.client, error: error, message: "Failed to apply fallback color depth for stream \(streamID): ")
                }
            }
            return
        }

        guard let currentBitrate = adaptiveFallbackBitrateByStream[streamID], currentBitrate > 0 else {
            MirageLogger.client("Adaptive fallback skipped (missing current bitrate) for stream \(streamID)")
            return
        }
        guard let nextBitrate = Self.nextAdaptiveFallbackBitrate(
            currentBitrate: currentBitrate,
            step: adaptiveFallbackBitrateStep,
            floor: adaptiveFallbackBitrateFloorBps
        ) else {
            let floorText = Double(adaptiveFallbackBitrateFloorBps / 1_000_000)
                .formatted(.number.precision(.fractionLength(1)))
            MirageLogger.client("Adaptive fallback floor reached (\(floorText) Mbps) for stream \(streamID)")
            return
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                try await sendStreamEncoderSettingsChange(streamID: streamID, bitrate: nextBitrate)
                adaptiveFallbackBitrateByStream[streamID] = nextBitrate
                adaptiveFallbackLastAppliedTime[streamID] = CFAbsoluteTimeGetCurrent()
                let fromMbps = (Double(currentBitrate) / 1_000_000.0)
                    .formatted(.number.precision(.fractionLength(1)))
                let toMbps = (Double(nextBitrate) / 1_000_000.0)
                    .formatted(.number.precision(.fractionLength(1)))
                MirageLogger.client("Adaptive fallback bitrate step \(fromMbps) -> \(toMbps) Mbps for stream \(streamID)")
            } catch {
                MirageLogger.error(.client, error: error, message: "Failed to apply adaptive fallback for stream \(streamID): ")
            }
        }
    }

    private func nextCustomFallbackColorDepth(_ current: MirageStreamColorDepth) -> MirageStreamColorDepth? {
        switch current {
        case .ultra:
            .pro
        case .pro:
            .standard
        case .standard:
            nil
        }
    }

    private func nextCustomRestoreColorDepth(
        current: MirageStreamColorDepth,
        baseline: MirageStreamColorDepth
    ) -> MirageStreamColorDepth? {
        if current == baseline { return nil }
        switch current {
        case .standard:
            if baseline == .ultra { return .pro }
            return baseline == .pro ? .pro : nil
        case .pro:
            return baseline == .ultra ? .ultra : nil
        case .ultra:
            return nil
        }
    }

    nonisolated static func nextAdaptiveFallbackBitrate(
        currentBitrate: Int,
        step: Double,
        floor: Int
    )
    -> Int? {
        guard currentBitrate > 0 else { return nil }
        let clampedStep = max(0.0, min(step, 1.0))
        let clampedFloor = max(1, floor)
        let steppedBitrate = Int((Double(currentBitrate) * clampedStep).rounded(.down))
        let nextBitrate = max(clampedFloor, steppedBitrate)
        return nextBitrate < currentBitrate ? nextBitrate : nil
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
