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
    /// Start UDP connection to host's data port for receiving video.
    func startVideoConnection() async throws {
        guard hostDataPort > 0 else { throw MirageError.protocolError("Host data port not set") }
        let candidates = try await resolveMediaTransportCandidates()
        let candidateSummary = candidates.map { "\($0.label)=\($0.host):p2p=\($0.includePeerToPeer)" }.joined(separator: ", ")
        MirageLogger.client("Video UDP candidates: \(candidateSummary)")
        var lastError: Error?
        for (index, candidate) in candidates.enumerated() {
            do {
                MirageLogger.client(
                    "Connecting to host data port via \(candidate.label): \(candidate.host):\(hostDataPort) (p2p=\(candidate.includePeerToPeer))"
                )
                let udpConn = try await establishMediaUDPConnection(
                    host: candidate.host,
                    port: hostDataPort,
                    includePeerToPeer: candidate.includePeerToPeer,
                    serviceClass: .interactiveVideo,
                    qos: .userInteractive,
                    pathDescription: describeNetworkPath
                ) { [weak self] snapshot in
                    self?.handleVideoPathUpdate(snapshot)
                }
                udpConnection?.cancel()
                udpConnection = udpConn
                mediaTransportHost = candidate.host
                mediaTransportIncludePeerToPeer = candidate.includePeerToPeer
                MirageLogger.client("UDP connection established to host data port")
                if let path = udpConn.currentPath {
                    MirageLogger.client("UDP connection path: \(describeNetworkPath(path))")
                    handleVideoPathUpdate(MirageNetworkPathClassifier.classify(path))
                }
                startReceivingVideo()
                updateRegistrationRefreshLoopState()
                return
            } catch {
                lastError = error
                MirageLogger.client(
                    "UDP attempt \(index + 1)/\(candidates.count) failed via \(candidate.label): \(error.localizedDescription)"
                )
            }
        }

        throw lastError ?? MirageError.protocolError("Unable to establish UDP connection to host data port")
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

                            guard let packetContext = service.fastPathState.videoPacketContext(for: streamID) else {
                                receiveNext()
                                return
                            }

                            if packetContext.consumedStartupPending {
                                Task { @MainActor in
                                    service.logStartupFirstPacketIfNeeded(streamID: streamID)
                                    service.cancelStartupRegistrationRetry(streamID: streamID)
                                }
                            }

                            guard let reassembler = packetContext.reassembler else {
                                receiveNext()
                                return
                            }

                            let wirePayload = data.dropFirst(mirageHeaderSize)
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
                                guard let mediaPacketKey = packetContext.mediaPacketKey else {
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
                                        key: mediaPacketKey,
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
                                payload = Data(wirePayload)
                            }

                            reassembler.processPacket(payload, header: header)
                        }
                    }

                    if let error {
                        if MirageClientService.isExpectedTransportTermination(error) {
                            MirageLogger.client("UDP receive loop ended by peer/network: \(error.localizedDescription)")
                        } else {
                            MirageLogger.error(.client, error: error, message: "UDP receive error: ")
                        }
                        return
                    }

                    receiveNext()
                }
        }

        receiveNext()
    }

    /// Send stream registration to host via UDP.
    func sendStreamRegistration(
        streamID: StreamID,
        markKeyframeCooldown: Bool = true
    ) async throws {
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
        if markKeyframeCooldown {
            lastKeyframeRequestTime[streamID] = CFAbsoluteTimeGetCurrent()
        }
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
        videoPathSnapshot = nil
        mediaTransportHost = nil
        mediaTransportIncludePeerToPeer = nil
    }

    func resolveMediaTransportCandidates(
        preferredHost: NWEndpoint.Host? = nil,
        preferredIncludePeerToPeer: Bool? = nil
    ) async throws -> [UDPTransportCandidate] {
        let configuredPeerToPeer = networkConfig.enablePeerToPeer

        let connectedHostEndpoint = connectedHost?.endpoint
        let controlRemoteEndpoint = await currentControlRemoteEndpoint()
        let controlPathSnapshot = await currentControlPathSnapshot()
        let controlPathKind = controlPathSnapshot.map { MirageNetworkPathClassifier.classify($0).kind }
        let serviceHostName = Self.serviceName(from: connectedHostEndpoint)
            ?? connectedHost?.name
            ?? Self.serviceName(from: controlRemoteEndpoint)
        let serviceHost = serviceHostName.map { NWEndpoint.Host($0) }
        let connectedHostEndpointHost = Self.host(from: connectedHostEndpoint)
        let remoteHost = Self.host(from: controlPathSnapshot?.remoteEndpoint)
        let endpointHost = connectedHostEndpointHost ?? Self.host(from: controlRemoteEndpoint)

        let candidates = Self.orderedMediaTransportCandidates(
            preferredHost: preferredHost,
            preferredIncludePeerToPeer: preferredIncludePeerToPeer,
            serviceHost: serviceHost,
            remoteHost: remoteHost,
            endpointHost: endpointHost,
            configuredPeerToPeer: configuredPeerToPeer,
            controlPathKind: controlPathKind
        )

        guard !candidates.isEmpty else {
            throw MirageError.protocolError("Cannot determine host address")
        }
        return candidates
    }

    nonisolated static func orderedMediaTransportCandidates(
        preferredHost: NWEndpoint.Host?,
        preferredIncludePeerToPeer: Bool?,
        serviceHost: NWEndpoint.Host?,
        remoteHost: NWEndpoint.Host?,
        endpointHost: NWEndpoint.Host?,
        configuredPeerToPeer: Bool,
        controlPathKind: MirageNetworkPathKind?
    ) -> [UDPTransportCandidate] {
        var candidates: [UDPTransportCandidate] = []
        var seen: Set<String> = []

        func appendCandidate(host: NWEndpoint.Host, includePeerToPeer: Bool, label: String) {
            let key = "\(String(describing: host).lowercased())|p2p=\(includePeerToPeer)"
            guard seen.insert(key).inserted else { return }
            candidates.append(
                UDPTransportCandidate(
                    host: host,
                    includePeerToPeer: includePeerToPeer,
                    label: label
                )
            )
        }

        if let preferredHost {
            appendCandidate(
                host: preferredHost,
                includePeerToPeer: preferredIncludePeerToPeer ?? configuredPeerToPeer,
                label: "preferred-route"
            )
        }

        let shouldPreferControlRemoteEndpoint = if let remoteHost {
            controlPathKind == .wired && isLikelyPeerToPeerLinkLocalHost(remoteHost)
        } else {
            false
        }

        if shouldPreferControlRemoteEndpoint, let remoteHost {
            appendCandidate(
                host: remoteHost,
                includePeerToPeer: configuredPeerToPeer,
                label: "control-remote-endpoint"
            )
        }

        if let remoteHost,
           isLikelyPeerToPeerLinkLocalHost(remoteHost),
           let serviceHost {
            for candidateHost in expandedBonjourHosts(for: serviceHost) {
                appendCandidate(
                    host: candidateHost,
                    includePeerToPeer: false,
                    label: "bonjour-hostname-no-p2p"
                )
            }
        }

        if !shouldPreferControlRemoteEndpoint, let remoteHost {
            appendCandidate(
                host: remoteHost,
                includePeerToPeer: configuredPeerToPeer,
                label: "control-remote-endpoint"
            )
        }

        if let endpointHost {
            appendCandidate(
                host: endpointHost,
                includePeerToPeer: configuredPeerToPeer,
                label: "control-endpoint"
            )
        }

        if let serviceHost {
            for candidateHost in expandedBonjourHosts(for: serviceHost) {
                appendCandidate(
                    host: candidateHost,
                    includePeerToPeer: configuredPeerToPeer,
                    label: "bonjour-hostname"
                )
                if configuredPeerToPeer {
                    appendCandidate(
                        host: candidateHost,
                        includePeerToPeer: false,
                        label: "bonjour-hostname-no-p2p"
                    )
                }
            }
        }

        return candidates
    }

    func establishMediaUDPConnection(
        host: NWEndpoint.Host,
        port: UInt16,
        includePeerToPeer: Bool,
        serviceClass: NWParameters.ServiceClass,
        qos: DispatchQoS.QoSClass,
        pathDescription: @Sendable @escaping (NWPath) -> String,
        onPathSnapshot: @Sendable @escaping @MainActor (MirageNetworkPathSnapshot) -> Void
    ) async throws -> NWConnection {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw MirageError.protocolError("Invalid host data port")
        }

        let endpoint = NWEndpoint.hostPort(host: host, port: endpointPort)
        let params = NWParameters.udp
        params.serviceClass = serviceClass
        params.includePeerToPeer = includePeerToPeer

        let udpConn = NWConnection(to: endpoint, using: params)
        udpConn.pathUpdateHandler = { path in
            let snapshot = MirageNetworkPathClassifier.classify(path)
            MirageLogger.client("UDP path updated: \(pathDescription(path))")
            Task { @MainActor in
                onPathSnapshot(snapshot)
            }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let box = ContinuationBox<Void>(continuation)
            let timeoutTask = Task {
                try? await Task.sleep(for: mediaTransportConnectTimeout)
                guard !Task.isCancelled else { return }
                box.resume(
                    throwing: MirageError.protocolError(
                        "UDP connection timed out after \(mediaTransportConnectTimeout)"
                    )
                )
                udpConn.cancel()
            }

            udpConn.stateUpdateHandler = { [box, timeoutTask] state in
                switch state {
                case .ready:
                    timeoutTask.cancel()
                    box.resume()
                case let .failed(error):
                    timeoutTask.cancel()
                    box.resume(throwing: error)
                case .cancelled:
                    timeoutTask.cancel()
                    box.resume(throwing: MirageError.protocolError("UDP connection cancelled"))
                case let .waiting(error):
                    if Self.shouldFailFastForWaitingMediaError(error) {
                        timeoutTask.cancel()
                        box.resume(throwing: error)
                        udpConn.cancel()
                    } else {
                        MirageLogger.client("UDP waiting for route to \(host):\(port): \(error)")
                    }
                default:
                    break
                }
            }

            udpConn.start(queue: .global(qos: qos))
        }

        return udpConn
    }

    nonisolated static func shouldFailFastForWaitingMediaError(_ error: NWError) -> Bool {
        guard case let .posix(code) = error else {
            return false
        }

        switch code {
        case .ENETDOWN, .ENETUNREACH, .ENETRESET, .EHOSTUNREACH, .EADDRNOTAVAIL, .EAFNOSUPPORT:
            return true
        default:
            return false
        }
    }

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

    nonisolated static func isLikelyPeerToPeerLinkLocalHost(_ host: NWEndpoint.Host) -> Bool {
        let value = String(describing: host).lowercased()
        return value.hasPrefix("fe80:") || value.contains("%awdl")
    }

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

    func handleVideoPathUpdate(_ snapshot: MirageNetworkPathSnapshot) {
        let previous = videoPathSnapshot
        videoPathSnapshot = snapshot
        Task { [weak self] in
            guard let self else { return }
            let controllers = Array(controllersByStream.values)
            for controller in controllers {
                await controller.setTransportPathKind(snapshot.kind)
            }
        }
        guard awdlExperimentEnabled else { return }
        guard Self.shouldTriggerPathRefresh(previous: previous, current: snapshot) else { return }
        if let previous, previous.kind != snapshot.kind {
            awdlPathSwitches &+= 1
            MirageLogger.client(
                "Video path switch \(previous.kind.rawValue) -> \(snapshot.kind.rawValue) (count \(awdlPathSwitches))"
            )
        }
        Task { [weak self] in
            await self?.refreshTransportRegistrations(reason: "video-path-change", triggerKeyframe: true)
        }
    }

    nonisolated static func shouldTriggerPathRefresh(
        previous: MirageNetworkPathSnapshot?,
        current: MirageNetworkPathSnapshot
    ) -> Bool {
        guard current.isReady else { return false }
        guard let previous else { return false }
        return previous.signature != current.signature
    }

    func refreshTransportRegistrations(
        reason: String,
        triggerKeyframe: Bool,
        streamFilter: Set<StreamID>? = nil
    ) async {
        guard awdlExperimentEnabled else { return }
        guard case .connected = connectionState else { return }

        let activeIDs = activeStreamIDsForFiltering
        guard !activeIDs.isEmpty else {
            updateRegistrationRefreshLoopState()
            return
        }

        let targetIDs: [StreamID] = {
            if let streamFilter {
                return activeIDs.filter { streamFilter.contains($0) }.sorted()
            }
            return activeIDs.sorted()
        }()
        guard !targetIDs.isEmpty else { return }

        do {
            if udpConnection == nil { try await startVideoConnection() }
        } catch {
            MirageLogger.error(.client, error: error, message: "Transport refresh (\(reason)) failed to start video connection: ")
            return
        }

        for streamID in targetIDs {
            do {
                try await sendStreamRegistration(
                    streamID: streamID,
                    markKeyframeCooldown: false
                )
                registrationRefreshCount &+= 1
                if triggerKeyframe { sendKeyframeRequest(for: streamID) }
            } catch {
                MirageLogger.error(
                    .client,
                    "Transport refresh (\(reason)) stream registration failed for stream \(streamID): \(error)"
                )
            }
        }

        await refreshAudioRegistration(
            reason: reason,
            streamFilter: Set(targetIDs)
        )
        logAwdlExperimentTelemetryIfNeeded()
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

        _ = sendControlMessageBestEffort(message)
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

        MirageLogger.client("Stream recovery requested for stream \(streamID) trigger=\(trigger.logLabel)")

        MirageFrameCache.shared.clear(for: streamID)

        Task { [weak self] in
            guard let self else { return }
            await controllersByStream[streamID]?.requestRecovery(
                reason: .manualRecovery,
                awaitFirstPresentedFrame: trigger.awaitFirstPresentedFrame,
                firstPresentedFrameWaitReason: trigger.firstPresentedFrameWaitReason
            )

            do {
                if udpConnection == nil { try await startVideoConnection() }
                try await sendStreamRegistration(streamID: streamID)
            } catch {
                MirageLogger.error(.client, error: error, message: "Stream recovery registration failed: ")
                stopVideoConnection()
            }
        }
    }

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
                    MirageLogger.client("Adaptive restore bitrate step \(fromMbps) → \(toMbps) Mbps for stream \(streamID)")
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
                            "Adaptive restore color depth step \(currentColorDepth.displayName) → \(nextColorDepth.displayName) for stream \(streamID)"
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
                MirageLogger.client("Adaptive fallback bitrate step \(fromMbps) → \(toMbps) Mbps for stream \(streamID)")
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
                    MirageLogger.client("Adaptive fallback color depth step \(currentName) → \(nextName) for stream \(streamID)")
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
                MirageLogger.client("Adaptive fallback bitrate step \(fromMbps) → \(toMbps) Mbps for stream \(streamID)")
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
}

struct UDPTransportCandidate {
    let host: NWEndpoint.Host
    let includePeerToPeer: Bool
    let label: String
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
