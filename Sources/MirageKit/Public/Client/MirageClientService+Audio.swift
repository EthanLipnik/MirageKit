//
//  MirageClientService+Audio.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/30/26.
//
//  Audio streaming and playback.
//

import Foundation
import Network

@MainActor
extension MirageClientService {
    func applyAudioPreferences(to request: inout StartStreamMessage) {
        request.audioMode = audioMode
        request.audioQuality = audioQuality
        request.audioMatchVideoQuality = audioMatchVideoQuality
    }

    func applyAudioPreferences(to request: inout StartDesktopStreamMessage) {
        request.audioMode = audioMode
        request.audioQuality = audioQuality
        request.audioMatchVideoQuality = audioMatchVideoQuality
    }

    func applyAudioPreferences(to request: inout SelectAppMessage) {
        request.audioMode = audioMode
        request.audioQuality = audioQuality
        request.audioMatchVideoQuality = audioMatchVideoQuality
    }

    func handleAudioStreamStarted(_ message: ControlMessage) {
        do {
            let started = try message.decode(AudioStreamStartedMessage.self)
            currentAudioConfig = started.config
            if started.audioPort > 0 {
                hostAudioPort = started.audioPort
            }
            Task {
                do {
                    try await startAudioConnection()
                    configureAudioPipeline(using: started.config)
                } catch {
                    MirageLogger.error(.client, "Failed to start audio connection: \(error)")
                }
            }
        } catch {
            MirageLogger.error(.client, "Failed to decode audioStreamStarted: \(error)")
        }
    }

    func handleAudioStreamStopped(_ message: ControlMessage) {
        if let stopped = try? message.decode(AudioStreamStoppedMessage.self) {
            MirageLogger.client("Audio stream stopped: \(stopped.reason)")
        }
        stopAudioPlayback()
    }

    private func configureAudioPipeline(using config: AudioConfigMessage) {
        if let current = currentAudioConfig,
           current.codec == config.codec,
           current.channelCount == config.channelCount,
           current.sampleRate == config.sampleRate,
           current.channelLayout == config.channelLayout,
           audioDecoder != nil,
           audioPlayer != nil {
            return
        }

        currentAudioConfig = config
        guard let decoder = AudioDecoder(config: config) else {
            MirageLogger.error(.client, "Failed to configure audio decoder")
            return
        }
        audioDecoder = decoder
        let player = AudioPlayer()
        audioPlayer = player
        player.start(format: decoder.playbackFormat)
    }

    private func startAudioConnection() async throws {
        guard audioMode != .off else { return }
        if audioConnection != nil { return }
        guard hostAudioPort > 0 else { throw MirageError.protocolError("Host audio port not set") }
        guard let connection = self.connection else { throw MirageError.protocolError("No TCP connection") }

        let host: NWEndpoint.Host
        if case .hostPort(let h, _) = connection.endpoint {
            host = h
        } else if let remoteEndpoint = connection.currentPath?.remoteEndpoint,
                  case .hostPort(let h, _) = remoteEndpoint {
            host = h
        } else if case .service(_, _, _, _) = connection.endpoint, let connectedHost {
            host = NWEndpoint.Host(connectedHost.name)
        } else {
            throw MirageError.protocolError("Cannot determine host address")
        }

        let audioEndpoint = NWEndpoint.hostPort(host: host, port: NWEndpoint.Port(rawValue: hostAudioPort)!)
        let params = NWParameters.udp
        params.serviceClass = .interactiveVideo
        params.includePeerToPeer = networkConfig.enablePeerToPeer

        let udpConn = NWConnection(to: audioEndpoint, using: params)
        audioConnection = udpConn

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let box = ContinuationBox<Void>(continuation)
            udpConn.stateUpdateHandler = { [box] state in
                switch state {
                case .ready:
                    box.resume()
                case .failed(let error):
                    box.resume(throwing: error)
                case .cancelled:
                    box.resume(throwing: MirageError.protocolError("Audio UDP connection cancelled"))
                default:
                    break
                }
            }
            udpConn.start(queue: .global(qos: .userInteractive))
        }

        MirageLogger.client("Audio UDP connection established")
        try await sendAudioRegistration()
        startReceivingAudio()
    }

    private func startReceivingAudio() {
        guard let audioConnection else { return }
        startAudioReceiveLoop(udpConnection: audioConnection, service: self)
    }

    private nonisolated func startAudioReceiveLoop(
        udpConnection: NWConnection,
        service: MirageClientService
    ) {
        @Sendable func receiveNext() {
            udpConnection.receive(minimumIncompleteLength: MirageAudioHeaderSize, maximumLength: 65_536) { data, _, isComplete, error in
                if let data, data.count >= MirageAudioHeaderSize {
                    if let header = AudioPacketHeader.deserialize(from: data) {
                        let payload = data.dropFirst(MirageAudioHeaderSize)
                        if payload.count == Int(header.payloadLength) {
                            Task { @MainActor in
                                service.handleAudioPacket(Data(payload), header: header)
                            }
                        }
                    }
                }

                if let error {
                    MirageLogger.error(.client, "Audio UDP receive error: \(error)")
                    return
                }

                if isComplete {
                    MirageLogger.client("Audio UDP connection closed")
                    return
                }

                receiveNext()
            }
        }

        receiveNext()
    }

    private func handleAudioPacket(_ payload: Data, header: AudioPacketHeader) {
        guard let config = currentAudioConfig else { return }
        audioPacketCount &+= 1
        if !audioFirstPacketReceived {
            audioFirstPacketReceived = true
            MirageLogger.client("Received first audio packet (\(payload.count) bytes)")
        }
        if needsAudioReconfigure(current: config, header: header) {
            let updated = AudioConfigMessage(
                mode: config.mode,
                quality: config.quality,
                matchVideoQuality: config.matchVideoQuality,
                codec: decodeCodec(header.codec),
                sampleRate: Int(header.sampleRate),
                channelCount: Int(header.channelCount),
                channelLayout: decodeLayout(header.channelLayout),
                bitrate: config.bitrate
            )
            configureAudioPipeline(using: updated)
        }

        guard let decoder = audioDecoder, let player = audioPlayer else { return }
        guard let pcmBuffer = decoder.decode(payload) else {
            let now = CFAbsoluteTimeGetCurrent()
            if now - audioLastEmptyBufferLogTime > 2.0 {
                MirageLogger.error(.client, "Audio decode produced no buffer")
                audioLastEmptyBufferLogTime = now
            }
            return
        }
        if pcmBuffer.frameLength == 0 {
            let now = CFAbsoluteTimeGetCurrent()
            if now - audioLastEmptyBufferLogTime > 2.0 {
                MirageLogger.error(.client, "Audio decode produced empty buffer")
                audioLastEmptyBufferLogTime = now
            }
            return
        }
        player.enqueue(pcmBuffer, timestamp: header.timestamp, discontinuity: header.flags.contains(.discontinuity))
    }

    private func needsAudioReconfigure(current: AudioConfigMessage, header: AudioPacketHeader) -> Bool {
        if Int(header.sampleRate) != current.sampleRate { return true }
        if Int(header.channelCount) != current.channelCount { return true }
        if decodeCodec(header.codec) != current.codec { return true }
        if decodeLayout(header.channelLayout) != current.channelLayout { return true }
        return false
    }

    private func decodeCodec(_ value: UInt8) -> MirageAudioCodec {
        switch value {
        case 2: return .pcmFloat32
        default: return .aacLc
        }
    }

    private func decodeLayout(_ value: UInt8) -> MirageAudioChannelLayout {
        switch value {
        case 1: return .mono
        case 2: return .stereo
        case 6: return .surround5_1
        default: return .source
        }
    }

    private func sendAudioRegistration() async throws {
        guard let audioConnection else {
            throw MirageError.protocolError("No audio UDP connection")
        }

        var data = Data()
        data.append(contentsOf: [0x4D, 0x49, 0x52, 0x41])
        withUnsafeBytes(of: deviceID.uuid) { data.append(contentsOf: $0) }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            audioConnection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func stopAudioPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        audioDecoder = nil
        currentAudioConfig = nil
        audioPacketCount = 0
        audioFirstPacketReceived = false
        audioLastEmptyBufferLogTime = 0
        stopAudioConnection()
    }

    func stopAudioConnection() {
        audioConnection?.cancel()
        audioConnection = nil
        hostAudioPort = 0
    }
}
