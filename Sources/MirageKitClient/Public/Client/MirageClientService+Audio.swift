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
            MirageLogger.error(.client, error: error, message: "Failed to establish audio transport: ")
            stopAudioConnection()
        }
    }

    func startAudioConnection() async throws {
        guard hostDataPort > 0 else { throw MirageError.protocolError("Host data port not set") }
        let candidates = try await resolveMediaTransportCandidates(
            preferredHost: mediaTransportHost,
            preferredIncludePeerToPeer: mediaTransportIncludePeerToPeer
        )
        let candidateSummary = candidates.map { "\($0.label)=\($0.host):p2p=\($0.includePeerToPeer)" }.joined(separator: ", ")
        MirageLogger.client("Audio UDP candidates: \(candidateSummary)")
        var lastError: Error?
        for (index, candidate) in candidates.enumerated() {
            do {
                MirageLogger.client(
                    "Connecting audio transport via \(candidate.label): \(candidate.host):\(hostDataPort) (p2p=\(candidate.includePeerToPeer))"
                )
                let udpConn = try await establishMediaUDPConnection(
                    host: candidate.host,
                    port: hostDataPort,
                    includePeerToPeer: candidate.includePeerToPeer,
                    serviceClass: .background,
                    qos: .utility,
                    pathDescription: describeAudioNetworkPath
                ) { [weak self] snapshot in
                    self?.handleAudioPathUpdate(snapshot)
                }
                audioConnection?.cancel()
                audioConnection = udpConn
                MirageLogger.client("Audio UDP connection established")
                if let path = udpConn.currentPath {
                    MirageLogger.client("Audio UDP path: \(describeAudioNetworkPath(path))")
                    handleAudioPathUpdate(MirageNetworkPathClassifier.classify(path))
                }
                startReceivingAudio()
                return
            } catch {
                lastError = error
                MirageLogger.client(
                    "Audio UDP attempt \(index + 1)/\(candidates.count) failed via \(candidate.label): \(error.localizedDescription)"
                )
            }
        }

        throw lastError ?? MirageError.protocolError("Unable to establish audio UDP connection")
    }

    func stopAudioConnection() {
        audioConnection?.cancel()
        audioConnection = nil
        audioPathSnapshot = nil
        audioRegisteredStreamID = nil
        activeAudioStreamMessage = nil
        setActiveAudioStreamIDForFiltering(nil)
        setAudioDecodeTargetChannelCountForPipeline(2)
        audioPlaybackController.setRuntimeExtraDelay(seconds: 0)
        audioPlaybackController.reset()
        Task { [audioPacketIngressQueue] in
            await audioPacketIngressQueue.reset()
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

    func handleAudioPathUpdate(_ snapshot: MirageNetworkPathSnapshot) {
        let previous = audioPathSnapshot
        audioPathSnapshot = snapshot
        guard awdlExperimentEnabled else { return }
        guard MirageClientService.shouldTriggerPathRefresh(previous: previous, current: snapshot) else { return }
        if let previous, previous.kind != snapshot.kind {
            awdlPathSwitches &+= 1
            MirageLogger.client(
                "Audio path switch \(previous.kind.rawValue) -> \(snapshot.kind.rawValue) (count \(awdlPathSwitches))"
            )
        }
        Task { [weak self] in
            await self?.refreshTransportRegistrations(reason: "audio-path-change", triggerKeyframe: true)
        }
    }

    func refreshAudioRegistration(
        reason: String,
        streamFilter: Set<StreamID>? = nil
    ) async {
        guard awdlExperimentEnabled else { return }
        guard audioConfiguration.enabled else { return }
        guard let streamID = activeAudioStreamMessage?.streamID else { return }
        if let streamFilter, !streamFilter.contains(streamID) { return }

        do {
            if audioConnection == nil { try await startAudioConnection() }
            try await sendAudioRegistration(streamID: streamID)
            registrationRefreshCount &+= 1
        } catch {
            MirageLogger.error(.client, error: error, message: "Audio transport refresh (\(reason)) failed: ")
            stopAudioConnection()
        }
    }

    func handleAudioStreamStarted(_ message: ControlMessage) {
        do {
            let started = try message.decode(AudioStreamStartedMessage.self)
            let previous = activeAudioStreamMessage
            activeAudioStreamMessage = started
            setActiveAudioStreamIDForFiltering(started.streamID)
            let preferredChannels = audioPlaybackController.preferredChannelCount(
                for: Int(started.channelCount)
            )
            setAudioDecodeTargetChannelCountForPipeline(preferredChannels)

            MirageLogger
                .client(
                    "Audio stream started: stream=\(started.streamID), codec=\(started.codec), sampleRate=\(started.sampleRate), channels=\(started.channelCount)"
                )

            Task { [weak self] in
                guard let self else { return }
                if previous != started {
                    await self.audioPacketIngressQueue.reset()
                    self.audioPlaybackController.reset()
                }
                await self.ensureAudioTransportRegistered(for: started.streamID)
            }
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to decode audioStreamStarted: ")
        }
    }

    func handleAudioStreamStopped(_ message: ControlMessage) {
        do {
            let stopped = try message.decode(AudioStreamStoppedMessage.self)
            MirageLogger.client("Audio stream stopped: stream=\(stopped.streamID), reason=\(stopped.reason)")
            let shouldReset = activeAudioStreamMessage?.streamID == stopped.streamID
            guard shouldReset else { return }

            activeAudioStreamMessage = nil
            setActiveAudioStreamIDForFiltering(nil)
            setAudioDecodeTargetChannelCountForPipeline(2)

            Task { [weak self] in
                guard let self else { return }
                await self.audioPacketIngressQueue.reset()
                self.audioPlaybackController.setRuntimeExtraDelay(seconds: 0)
                self.audioPlaybackController.reset()
            }
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to decode audioStreamStopped: ")
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

                    guard let packetContext = service.fastPathState.audioPacketContext(for: header.streamID) else {
                        receiveNext()
                        return
                    }

                    let generation = service.audioPacketIngressQueue.currentGeneration()
                    let wirePayload = data.dropFirst(mirageAudioHeaderSize)
                    let expectedWireLength = header.flags.contains(.encryptedPayload)
                        ? Int(header.payloadLength) + MirageMediaSecurity.authTagLength
                        : Int(header.payloadLength)
                    guard wirePayload.count == expectedWireLength else {
                        receiveNext()
                        return
                    }
                    let payloadData: Data
                    if header.flags.contains(.encryptedPayload) {
                        guard let mediaPacketKey = packetContext.mediaPacketKey else {
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
                                key: mediaPacketKey,
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
                        payloadData = Data(wirePayload)
                    }
                    if Self.shouldValidateAudioChecksum(flags: header.flags, checksum: header.checksum) {
                        guard CRC32.calculate(payloadData) == header.checksum else {
                            receiveNext()
                            return
                        }
                    }

                    service.audioPacketIngressQueue.enqueue(
                        header: header,
                        payload: payloadData,
                        targetChannelCount: packetContext.targetChannelCount,
                        generation: generation
                    )
                }

                if let error {
                    if MirageClientService.isExpectedTransportTermination(error) {
                        MirageLogger.client("Audio UDP receive loop ended by peer/network: \(error.localizedDescription)")
                    } else {
                        MirageLogger.error(.client, error: error, message: "Audio UDP receive error: ")
                    }
                    return
                }

                receiveNext()
            }
        }

        receiveNext()
    }

    nonisolated static func shouldValidateAudioChecksum(flags: AudioPacketFlags, checksum: UInt32) -> Bool {
        mirageShouldValidatePayloadChecksum(
            isEncrypted: flags.contains(.encryptedPayload),
            checksum: checksum
        )
    }

    func enqueueDecodedAudioFrames(_ decodedFrames: [DecodedPCMFrame], for streamID: StreamID) {
        guard audioConfiguration.enabled else { return }
        guard activeAudioStreamMessage?.streamID == streamID else { return }
        guard !decodedFrames.isEmpty else { return }
        updateAudioSyncDelay(for: streamID)
        for decodedFrame in decodedFrames {
            audioPlaybackController.enqueue(decodedFrame)
        }
    }

    private func updateAudioSyncDelay(for streamID: StreamID) {
        guard let snapshot = metricsStore.snapshot(for: streamID) else {
            audioPlaybackController.setRuntimeExtraDelay(seconds: 0)
            return
        }

        let delaySeconds = Self.resolveAudioSyncDelaySeconds(
            snapshot: snapshot,
            fallbackTargetFPS: getScreenMaxRefreshRate()
        )
        audioPlaybackController.setRuntimeExtraDelay(seconds: delaySeconds)
    }

    nonisolated static func resolveAudioSyncDelaySeconds(
        snapshot: MirageClientMetricsSnapshot,
        fallbackTargetFPS: Int
    ) -> Double {
        _ = snapshot
        _ = fallbackTargetFPS
        return 0
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
