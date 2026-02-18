//
//  MirageClientService+Audio.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/6/26.
//
//  Dedicated UDP audio transport and playback handling.
//

import Foundation
import Network
import MirageKit

@MainActor
extension MirageClientService {
    func ensureAudioTransportRegistered(for streamID: StreamID) async {
        guard audioConfiguration.enabled else { return }

        do {
            if audioConnection == nil { try await startAudioConnection() }
            try await sendAudioRegistration(streamID: streamID)
        } catch {
            MirageLogger.error(.client, "Failed to establish audio transport: \(error)")
            stopAudioConnection()
        }
    }

    func startAudioConnection() async throws {
        guard hostDataPort > 0 else { throw MirageError.protocolError("Host data port not set") }
        guard let connection else { throw MirageError.protocolError("No TCP connection") }

        let host: NWEndpoint.Host
        if case let .hostPort(endpointHost, _) = connection.endpoint {
            host = endpointHost
        } else if let remoteEndpoint = connection.currentPath?.remoteEndpoint,
                  case let .hostPort(endpointHost, _) = remoteEndpoint {
            host = endpointHost
        } else if case .service = connection.endpoint, let connectedHost {
            host = NWEndpoint.Host(connectedHost.name)
        } else {
            throw MirageError.protocolError("Cannot determine host address for audio")
        }

        guard let port = NWEndpoint.Port(rawValue: hostDataPort) else {
            throw MirageError.protocolError("Invalid host data port for audio")
        }
        let endpoint = NWEndpoint.hostPort(
            host: host,
            port: port
        )
        let params = NWParameters.udp
        params.serviceClass = .background
        params.includePeerToPeer = networkConfig.enablePeerToPeer

        let udpConn = NWConnection(to: endpoint, using: params)
        audioConnection = udpConn
        udpConn.pathUpdateHandler = { path in
            MirageLogger.client("Audio UDP path updated: \(describeAudioNetworkPath(path))")
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
                    box.resume(throwing: MirageError.protocolError("Audio UDP connection cancelled"))
                default:
                    break
                }
            }
            udpConn.start(queue: .global(qos: .utility))
        }

        MirageLogger.client("Audio UDP connection established")
        if let path = udpConn.currentPath {
            MirageLogger.client("Audio UDP path: \(describeAudioNetworkPath(path))")
        }
        startReceivingAudio()
    }

    func stopAudioConnection() {
        audioConnection?.cancel()
        audioConnection = nil
        audioRegisteredStreamID = nil
        activeAudioStreamMessage = nil
        audioPlaybackController.setRuntimeExtraDelay(seconds: 0)
        audioPlaybackController.reset()
        Task {
            await audioJitterBuffer.reset()
            await audioDecoder.reset()
        }
    }

    func sendAudioRegistration(streamID: StreamID) async throws {
        guard let audioConnection else { throw MirageError.protocolError("No audio UDP connection") }
        guard audioRegisteredStreamID != streamID else { return }
        guard let mediaSecurityContext else {
            throw MirageError.protocolError("Missing media security context")
        }

        var data = Data()
        // Registration packets use network byte order for magic bytes ("MIRA").
        withUnsafeBytes(of: mirageAudioRegistrationMagic.bigEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: streamID.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: deviceID.uuid) { data.append(contentsOf: $0) }
        data.append(mediaSecurityContext.udpRegistrationToken)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            audioConnection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else {
                    continuation.resume()
                }
            })
        }

        audioRegisteredStreamID = streamID
        MirageLogger.client(
            "Audio registration sent for stream \(streamID) (tokenBytes=\(mediaSecurityContext.udpRegistrationToken.count))"
        )
    }

    func handleAudioStreamStarted(_ message: ControlMessage) {
        do {
            let started = try message.decode(AudioStreamStartedMessage.self)
            let previous = activeAudioStreamMessage
            activeAudioStreamMessage = started

            MirageLogger
                .client(
                    "Audio stream started: stream=\(started.streamID), codec=\(started.codec), sampleRate=\(started.sampleRate), channels=\(started.channelCount)"
                )

            Task { [weak self] in
                guard let self else { return }
                if previous != started {
                    await self.audioJitterBuffer.reset()
                    await self.audioDecoder.reset()
                    self.audioPlaybackController.reset()
                }
                await self.ensureAudioTransportRegistered(for: started.streamID)
            }
        } catch {
            MirageLogger.error(.client, "Failed to decode audioStreamStarted: \(error)")
        }
    }

    func handleAudioStreamStopped(_ message: ControlMessage) {
        do {
            let stopped = try message.decode(AudioStreamStoppedMessage.self)
            MirageLogger.client("Audio stream stopped: stream=\(stopped.streamID), reason=\(stopped.reason)")
            if activeAudioStreamMessage?.streamID == stopped.streamID {
                activeAudioStreamMessage = nil
            }

            Task { [weak self] in
                guard let self else { return }
                await self.audioJitterBuffer.reset()
                await self.audioDecoder.reset()
                self.audioPlaybackController.setRuntimeExtraDelay(seconds: 0)
                self.audioPlaybackController.reset()
            }
        } catch {
            MirageLogger.error(.client, "Failed to decode audioStreamStopped: \(error)")
        }
    }

    private func startReceivingAudio() {
        guard let audioConnection else { return }
        startAudioUDPReceiveLoop(audioConnection: audioConnection, service: self)
    }

    private nonisolated func startAudioUDPReceiveLoop(
        audioConnection: NWConnection,
        service: MirageClientService
    ) {
        @Sendable
        func receiveNext() {
            audioConnection.receive(minimumIncompleteLength: mirageAudioHeaderSize, maximumLength: 65536) {
                data,
                _,
                _,
                error in
                if let data {
                    guard data.count >= mirageAudioHeaderSize,
                          let header = AudioPacketHeader.deserialize(from: data) else {
                        receiveNext()
                        return
                    }

                    let wirePayload = Data(data.dropFirst(mirageAudioHeaderSize))
                    let expectedWireLength = header.flags.contains(.encryptedPayload)
                        ? Int(header.payloadLength) + MirageMediaSecurity.authTagLength
                        : Int(header.payloadLength)
                    guard wirePayload.count == expectedWireLength else {
                        receiveNext()
                        return
                    }
                    let payloadData: Data
                    if header.flags.contains(.encryptedPayload) {
                        guard let mediaSecurityContext = service.mediaSecurityContextForNetworking else {
                            MirageLogger.error(
                                .client,
                                "Dropping encrypted audio packet without media security context (stream \(header.streamID))"
                            )
                            receiveNext()
                            return
                        }
                        do {
                            payloadData = try MirageMediaSecurity.decryptAudioPayload(
                                wirePayload,
                                header: header,
                                context: mediaSecurityContext,
                                direction: .hostToClient
                            )
                        } catch {
                            MirageLogger.error(
                                .client,
                                "Failed to decrypt audio packet stream \(header.streamID) frame \(header.frameNumber) seq \(header.sequenceNumber): \(error)"
                            )
                            receiveNext()
                            return
                        }
                        guard payloadData.count == Int(header.payloadLength) else {
                            receiveNext()
                            return
                        }
                    } else {
                        payloadData = wirePayload
                    }
                    guard CRC32.calculate(payloadData) == header.checksum else {
                        receiveNext()
                        return
                    }

                    Task { @MainActor [weak service] in
                        await service?.handleAudioPacket(header: header, payload: payloadData)
                    }
                }

                if let error {
                    MirageLogger.error(.client, "Audio UDP receive error: \(error)")
                    return
                }

                receiveNext()
            }
        }

        receiveNext()
    }

    private func handleAudioPacket(header: AudioPacketHeader, payload: Data) async {
        guard audioConfiguration.enabled else { return }
        if let activeAudioStreamMessage, activeAudioStreamMessage.streamID != header.streamID { return }
        updateAudioSyncDelay(for: header.streamID)

        let encodedFrames = await audioJitterBuffer.ingest(header: header, payload: payload)
        guard !encodedFrames.isEmpty else { return }

        for frame in encodedFrames {
            let preferredChannels = audioPlaybackController.preferredChannelCount(for: frame.channelCount)
            guard let decodedFrame = await audioDecoder.decode(frame, targetChannelCount: preferredChannels) else {
                continue
            }
            audioPlaybackController.enqueue(decodedFrame)
        }
    }

    private func updateAudioSyncDelay(for streamID: StreamID) {
        guard let snapshot = metricsStore.snapshot(for: streamID) else {
            audioPlaybackController.setRuntimeExtraDelay(seconds: 0)
            return
        }

        let typingBurstActive = MirageFrameCache.shared.isTypingBurstActive(for: streamID)
        let delaySeconds = Self.resolveAudioSyncDelaySeconds(
            latencyMode: latencyMode,
            typingBurstActive: typingBurstActive,
            snapshot: snapshot,
            fallbackTargetFPS: getScreenMaxRefreshRate()
        )
        audioPlaybackController.setRuntimeExtraDelay(seconds: delaySeconds)
    }

    nonisolated static func resolveAudioSyncDelaySeconds(
        latencyMode: MirageStreamLatencyMode,
        typingBurstActive: Bool,
        snapshot: MirageClientMetricsSnapshot,
        fallbackTargetFPS: Int
    ) -> Double {
        let bufferingAllowed = switch latencyMode {
        case .lowestLatency:
            false
        case .auto:
            !typingBurstActive
        case .smoothest:
            true
        }

        guard bufferingAllowed, !snapshot.decodeHealthy else { return 0 }

        let clampedDepth = min(max(0, snapshot.renderBufferDepth), MirageRenderModePolicy.maxStressBufferDepth)
        let delayedFrames = max(0, clampedDepth - 1)
        guard delayedFrames > 0 else { return 0 }

        let targetFPS = max(
            1,
            snapshot.hostTargetFrameRate > 0 ? snapshot.hostTargetFrameRate : fallbackTargetFPS
        )
        return Double(delayedFrames) / Double(targetFPS)
    }
}

private func describeAudioNetworkPath(_ path: NWPath) -> String {
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
