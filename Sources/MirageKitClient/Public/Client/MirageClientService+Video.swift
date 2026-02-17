//
//  MirageClientService+Video.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  UDP video transport and keyframe recovery.
//

import Foundation
import Network
import MirageKit

@MainActor
extension MirageClientService {
    /// Start UDP connection to host's data port for receiving video.
    func startVideoConnection() async throws {
        guard hostDataPort > 0 else { throw MirageError.protocolError("Host data port not set") }

        guard let connection else { throw MirageError.protocolError("No TCP connection") }

        let host: NWEndpoint.Host
        if case let .hostPort(h, _) = connection.endpoint { host = h } else if let remoteEndpoint = connection.currentPath?.remoteEndpoint,
                                                                               case let .hostPort(h, _) = remoteEndpoint {
            host = h
        } else {
            MirageLogger.client("Using Bonjour endpoint for UDP")
            if case .service = connection.endpoint {
                if let connectedHost {
                    let dataEndpoint = NWEndpoint.hostPort(
                        host: NWEndpoint.Host(connectedHost.name),
                        port: NWEndpoint.Port(rawValue: hostDataPort)!
                    )
                    MirageLogger
                        .client("Connecting to host data port via hostname \(connectedHost.name):\(hostDataPort)")
                    let params = NWParameters.udp
                    params.serviceClass = .interactiveVideo
                    params.includePeerToPeer = networkConfig.enablePeerToPeer

                    let udpConn = NWConnection(to: dataEndpoint, using: params)
                    udpConnection = udpConn
                    udpConn.pathUpdateHandler = { path in
                        MirageLogger.client("UDP path updated: \(describeNetworkPath(path))")
                    }

                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        let box = ContinuationBox<Void>(continuation)
                        udpConn.stateUpdateHandler = { [box] state in
                            switch state {
                            case .ready:
                                box.resume()
                            case let .failed(error):
                                box.resume(throwing: error)
                            case .cancelled:
                                box.resume(throwing: MirageError.protocolError("UDP connection cancelled"))
                            default:
                                break
                            }
                        }
                        udpConn.start(queue: .global(qos: .userInteractive))
                    }
                    MirageLogger.client("UDP connection established to host data port")
                    if let path = udpConn.currentPath {
                        MirageLogger.client("UDP connection path: \(describeNetworkPath(path))")
                    }
                    startReceivingVideo()
                    return
                }
            }
            throw MirageError.protocolError("Cannot determine host address")
        }

        let dataEndpoint = NWEndpoint.hostPort(host: host, port: NWEndpoint.Port(rawValue: hostDataPort)!)
        MirageLogger.client("Connecting to host data port at \(host):\(hostDataPort)")

        let params = NWParameters.udp
        params.serviceClass = .interactiveVideo
        params.includePeerToPeer = networkConfig.enablePeerToPeer

        let udpConn = NWConnection(to: dataEndpoint, using: params)
        udpConnection = udpConn
        udpConn.pathUpdateHandler = { path in
            MirageLogger.client("UDP path updated: \(describeNetworkPath(path))")
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let box = ContinuationBox<Void>(continuation)

            udpConn.stateUpdateHandler = { [box] state in
                switch state {
                case .ready:
                    box.resume()
                case let .failed(error):
                    box.resume(throwing: error)
                case .cancelled:
                    box.resume(throwing: MirageError.protocolError("UDP connection cancelled"))
                default:
                    break
                }
            }

            udpConn.start(queue: .global(qos: .userInteractive))
        }

        MirageLogger.client("UDP connection established to host data port")
        if let path = udpConn.currentPath {
            MirageLogger.client("UDP connection path: \(describeNetworkPath(path))")
        }
        startReceivingVideo()
    }

    /// Start receiving video data from UDP connection.
    private func startReceivingVideo() {
        guard let udpConn = udpConnection else { return }
        startUDPReceiveLoop(udpConnection: udpConn, service: self)
    }

    /// Start the UDP receive loop in a nonisolated context.
    private nonisolated func startUDPReceiveLoop(
        udpConnection: NWConnection,
        service: MirageClientService
    ) {
        @Sendable
        func receiveNext() {
            udpConnection
                .receive(minimumIncompleteLength: 4, maximumLength: 65536) { data, _, _, error in
                    if let data {
                        if let testHeader = QualityTestPacketHeader.deserialize(from: data) {
                            service.handleQualityTestPacket(testHeader, data: data)
                            receiveNext()
                            return
                        }

                        if data.count >= mirageHeaderSize, let header = FrameHeader.deserialize(from: data) {
                            let streamID = header.streamID

                            guard service.activeStreamIDsForFiltering.contains(streamID) else {
                                receiveNext()
                                return
                            }

                            if service.takeStartupPacketPending(streamID) {
                                Task { @MainActor in
                                    service.logStartupFirstPacketIfNeeded(streamID: streamID)
                                    service.cancelStartupRegistrationRetry(streamID: streamID)
                                }
                            }

                            guard let reassembler = service.reassemblerForStream(streamID) else {
                                receiveNext()
                                return
                            }

                            let wirePayload = Data(data.dropFirst(mirageHeaderSize))
                            let expectedWireLength = header.flags.contains(.encryptedPayload)
                                ? Int(header.payloadLength) + MirageMediaSecurity.authTagLength
                                : Int(header.payloadLength)
                            if wirePayload.count != expectedWireLength {
                                MirageLogger
                                    .client(
                                        "UDP payload length mismatch for stream \(streamID): expected=\(expectedWireLength), plain=\(header.payloadLength), actual=\(wirePayload.count), encrypted=\(header.flags.contains(.encryptedPayload))"
                                    )
                                receiveNext()
                                return
                            }
                            let payload: Data
                            if header.flags.contains(.encryptedPayload) {
                                guard let mediaSecurityContext = service.mediaSecurityContextForNetworking else {
                                    MirageLogger.error(
                                        .client,
                                        "Dropping encrypted video packet without media security context (stream \(streamID))"
                                    )
                                    receiveNext()
                                    return
                                }
                                do {
                                    payload = try MirageMediaSecurity.decryptVideoPayload(
                                        wirePayload,
                                        header: header,
                                        context: mediaSecurityContext,
                                        direction: .hostToClient
                                    )
                                } catch {
                                    MirageLogger.error(
                                        .client,
                                        "Failed to decrypt video packet stream \(streamID) frame \(header.frameNumber) seq \(header.sequenceNumber): \(error)"
                                    )
                                    receiveNext()
                                    return
                                }
                                if payload.count != Int(header.payloadLength) {
                                    MirageLogger.error(
                                        .client,
                                        "Decrypted video payload length mismatch for stream \(streamID): expected \(header.payloadLength), actual \(payload.count)"
                                    )
                                    receiveNext()
                                    return
                                }
                            } else {
                                payload = wirePayload
                            }

                            reassembler.processPacket(payload, header: header)
                        }
                    }

                    if let error {
                        MirageLogger.error(.client, "UDP receive error: \(error)")
                        return
                    }

                    receiveNext()
                }
        }

        receiveNext()
    }

    /// Send stream registration to host via UDP.
    func sendStreamRegistration(streamID: StreamID) async throws {
        guard let udpConn = udpConnection else { throw MirageError.protocolError("No UDP connection") }
        guard let mediaSecurityContext else {
            throw MirageError.protocolError("Missing media security context")
        }

        var data = Data()
        data.append(contentsOf: [0x4D, 0x49, 0x52, 0x47])
        withUnsafeBytes(of: streamID.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: deviceID.uuid) { data.append(contentsOf: $0) }
        data.append(mediaSecurityContext.udpRegistrationToken)

        MirageLogger.client(
            "Sending stream registration for stream \(streamID) (tokenBytes=\(mediaSecurityContext.udpRegistrationToken.count))"
        )

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            udpConn.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else {
                    continuation.resume()
                }
            })
        }

        MirageLogger.client("Stream registration sent")
        if let baseTime = streamStartupBaseTimes[streamID],
           !streamStartupFirstRegistrationSent.contains(streamID) {
            streamStartupFirstRegistrationSent.insert(streamID)
            let deltaMs = Int((CFAbsoluteTimeGetCurrent() - baseTime) * 1000)
            MirageLogger.client("Desktop start: stream registration sent for stream \(streamID) (+\(deltaMs)ms)")
        }
        lastKeyframeRequestTime[streamID] = CFAbsoluteTimeGetCurrent()
    }

    func logStartupFirstPacketIfNeeded(streamID: StreamID) {
        guard let baseTime = streamStartupBaseTimes[streamID],
              !streamStartupFirstPacketReceived.contains(streamID) else {
            return
        }
        streamStartupFirstPacketReceived.insert(streamID)
        let deltaMs = Int((CFAbsoluteTimeGetCurrent() - baseTime) * 1000)
        MirageLogger.client("Desktop start: first UDP packet received for stream \(streamID) (+\(deltaMs)ms)")
    }

    /// Stop the video connection.
    func stopVideoConnection() {
        udpConnection?.cancel()
        udpConnection = nil
        hostDataPort = 0
    }

    /// Request a keyframe from the host when decoder encounters errors.
    func sendKeyframeRequest(for streamID: StreamID) {
        guard case .connected = connectionState, let connection else {
            MirageLogger.client("Cannot send keyframe request - not connected")
            return
        }

        let now = CFAbsoluteTimeGetCurrent()
        if let lastTime = lastKeyframeRequestTime[streamID], now - lastTime < keyframeRequestCooldown {
            let remaining = Int(((keyframeRequestCooldown - (now - lastTime)) * 1000).rounded())
            MirageLogger.client("Keyframe request skipped (cooldown \(remaining)ms) for stream \(streamID)")
            return
        }
        lastKeyframeRequestTime[streamID] = now

        let request = KeyframeRequestMessage(streamID: streamID)
        guard let message = try? ControlMessage(type: .keyframeRequest, content: request) else {
            MirageLogger.error(.client, "Failed to create keyframe request message")
            return
        }

        let data = message.serialize()
        connection.send(content: data, completion: .idempotent)
        MirageLogger.client("Sent keyframe request for stream \(streamID)")
    }

    /// Request stream recovery by forcing a keyframe.
    public func requestStreamRecovery(for streamID: StreamID) {
        guard case .connected = connectionState else {
            MirageLogger.client("Stream recovery skipped - not connected")
            return
        }

        MirageLogger.client("Stream recovery requested for stream \(streamID)")

        MirageFrameCache.shared.clear(for: streamID)

        Task { [weak self] in
            guard let self else { return }
            await controllersByStream[streamID]?.requestRecovery(reason: .manualRecovery)

            do {
                if udpConnection == nil { try await startVideoConnection() }
                try await sendStreamRegistration(streamID: streamID)
            } catch {
                MirageLogger.error(.client, "Stream recovery registration failed: \(error)")
                stopVideoConnection()
            }
        }
    }

    func sendStreamEncoderSettingsChange(
        streamID: StreamID,
        bitDepth: MirageVideoBitDepth? = nil,
        bitrate: Int? = nil,
        streamScale: CGFloat? = nil
    )
    async throws {
        guard case .connected = connectionState, let connection else { throw MirageError.protocolError("Not connected") }
        guard bitDepth != nil || bitrate != nil || streamScale != nil else { return }

        let clampedScale = streamScale.map(clampStreamScale)
        let request = StreamEncoderSettingsChangeMessage(
            streamID: streamID,
            bitDepth: bitDepth,
            bitrate: bitrate,
            streamScale: clampedScale
        )
        let message = try ControlMessage(type: .streamEncoderSettingsChange, content: request)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: message.serialize(), completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else {
                    continuation.resume()
                }
            })
        }
    }

    func handleAdaptiveFallbackTrigger(for streamID: StreamID) {
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

    func configureAdaptiveFallbackBaseline(
        for streamID: StreamID,
        bitrate: Int?,
        bitDepth: MirageVideoBitDepth?
    ) {
        if let bitrate, bitrate > 0 {
            adaptiveFallbackBitrateByStream[streamID] = bitrate
            adaptiveFallbackBaselineBitrateByStream[streamID] = bitrate
        } else {
            adaptiveFallbackBitrateByStream.removeValue(forKey: streamID)
            adaptiveFallbackBaselineBitrateByStream.removeValue(forKey: streamID)
        }
        if let bitDepth {
            adaptiveFallbackBitDepthByStream[streamID] = bitDepth
            adaptiveFallbackBaselineBitDepthByStream[streamID] = bitDepth
        } else {
            adaptiveFallbackBitDepthByStream.removeValue(forKey: streamID)
            adaptiveFallbackBaselineBitDepthByStream.removeValue(forKey: streamID)
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
        adaptiveFallbackBitDepthByStream.removeValue(forKey: streamID)
        adaptiveFallbackBaselineBitDepthByStream.removeValue(forKey: streamID)
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

        let baselineBitDepth = adaptiveFallbackBaselineBitDepthByStream[streamID]
        let currentBitDepth = adaptiveFallbackBitDepthByStream[streamID]
        let baselineBitrate = adaptiveFallbackBaselineBitrateByStream[streamID]
        let currentBitrate = adaptiveFallbackBitrateByStream[streamID]

        let bitDepthDegraded = if let baselineBitDepth, let currentBitDepth {
            currentBitDepth != baselineBitDepth
        } else {
            false
        }
        let bitrateDegraded = if let baselineBitrate, let currentBitrate {
            currentBitrate < baselineBitrate
        } else {
            false
        }
        guard bitDepthDegraded || bitrateDegraded else {
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
                    MirageLogger.client("Adaptive restore bitrate step \(fromMbps) → \(toMbps) Mbps for stream \(streamID)")
                } catch {
                    MirageLogger.error(.client, "Failed to restore bitrate for stream \(streamID): \(error)")
                }
            }
            return
        }

        if bitDepthDegraded,
           let baselineBitDepth,
           let currentBitDepth,
           let nextBitDepth = nextCustomRestoreBitDepth(current: currentBitDepth, baseline: baselineBitDepth) {
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await sendStreamEncoderSettingsChange(
                        streamID: streamID,
                        bitDepth: nextBitDepth
                    )
                    adaptiveFallbackBitDepthByStream[streamID] = nextBitDepth
                    adaptiveFallbackLastAppliedTime[streamID] = CFAbsoluteTimeGetCurrent()
                    adaptiveFallbackLastRestoreTimeByStream[streamID] = CFAbsoluteTimeGetCurrent()
                    adaptiveFallbackStableSinceByStream[streamID] = CFAbsoluteTimeGetCurrent()
                    MirageLogger
                        .client(
                            "Adaptive restore bit depth step \(currentBitDepth.displayName) → \(nextBitDepth.displayName) for stream \(streamID)"
                        )
                } catch {
                    MirageLogger.error(.client, "Failed to restore bit depth for stream \(streamID): \(error)")
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
                MirageLogger.client("Adaptive fallback bitrate step \(fromMbps) → \(toMbps) Mbps for stream \(streamID)")
            } catch {
                MirageLogger.error(.client, "Failed to apply adaptive fallback for stream \(streamID): \(error)")
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

        if let currentBitDepth = adaptiveFallbackBitDepthByStream[streamID],
           let nextBitDepth = nextCustomFallbackBitDepth(currentBitDepth) {
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await sendStreamEncoderSettingsChange(
                        streamID: streamID,
                        bitDepth: nextBitDepth
                    )
                    adaptiveFallbackBitDepthByStream[streamID] = nextBitDepth
                    adaptiveFallbackLastAppliedTime[streamID] = CFAbsoluteTimeGetCurrent()
                    let currentName = currentBitDepth.displayName
                    let nextName = nextBitDepth.displayName
                    MirageLogger.client("Adaptive fallback bit depth step \(currentName) → \(nextName) for stream \(streamID)")
                } catch {
                    MirageLogger.error(.client, "Failed to apply fallback bit depth for stream \(streamID): \(error)")
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
                MirageLogger.client("Adaptive fallback bitrate step \(fromMbps) → \(toMbps) Mbps for stream \(streamID)")
            } catch {
                MirageLogger.error(.client, "Failed to apply adaptive fallback for stream \(streamID): \(error)")
            }
        }
    }

    private func nextCustomFallbackBitDepth(_ current: MirageVideoBitDepth) -> MirageVideoBitDepth? {
        switch current {
        case .tenBit:
            .eightBit
        case .eightBit:
            nil
        }
    }

    private func nextCustomRestoreBitDepth(
        current: MirageVideoBitDepth,
        baseline: MirageVideoBitDepth
    ) -> MirageVideoBitDepth? {
        if current == baseline { return nil }
        switch current {
        case .eightBit:
            return baseline == .tenBit ? .tenBit : nil
        case .tenBit:
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
}

private func describeNetworkPath(_ path: NWPath) -> String {
    var interfaces: [String] = []
    if path.usesInterfaceType(.wifi) { interfaces.append("wifi") }
    if path.usesInterfaceType(.wiredEthernet) { interfaces.append("wired") }
    if path.usesInterfaceType(.cellular) { interfaces.append("cellular") }
    if path.usesInterfaceType(.loopback) { interfaces.append("loopback") }
    if path.usesInterfaceType(.other) { interfaces.append("other") }
    let interfaceText = interfaces.isEmpty ? "unknown" : interfaces.joined(separator: ",")
    let available = path.availableInterfaces
        .map { "\($0.name)(\(String(describing: $0.type)))" }
        .joined(separator: ",")
    let availableText = available.isEmpty ? "none" : available
    return "status=\(path.status), interfaces=\(interfaceText), available=\(availableText), expensive=\(path.isExpensive), constrained=\(path.isConstrained), ipv4=\(path.supportsIPv4), ipv6=\(path.supportsIPv6)"
}
