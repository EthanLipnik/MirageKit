//
//  MirageHostService+Audio.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/30/26.
//
//  Audio capture and streaming.
//

import Foundation
import CoreMedia

#if os(macOS)

@MainActor
extension MirageHostService {
    enum AudioStreamKind: Sendable {
        case system
        case app(bundleIdentifier: String)
    }

    func configureAudioIfNeeded(
        for clientContext: ClientContext,
        streamKind: AudioStreamKind,
        preferredQuality: MirageQualityPreset,
        audioMode: MirageAudioMode?,
        audioQuality: MirageAudioQuality?,
        audioMatchVideoQuality: Bool?
    ) async {
        let resolvedMode = audioMode ?? .off
        guard resolvedMode != .off else {
            await stopAudioStreaming(reason: "Audio disabled")
            return
        }

        let baseQuality = audioQuality ?? .medium
        let shouldMatch = audioMatchVideoQuality ?? true
        let effectiveMatch = shouldMatch && preferredQuality != .custom
        let effectiveQuality = effectiveMatch ? audioQualityForPreset(preferredQuality) : baseQuality

        var config = MirageAudioConfiguration(
            mode: resolvedMode,
            quality: effectiveQuality,
            matchVideoQuality: effectiveMatch,
            sampleRate: 48_000,
            channelCount: channelCount(for: resolvedMode),
            channelLayout: channelLayout(for: resolvedMode),
            codec: resolvedMode == .full ? .pcmFloat32 : .aacLc,
            bitrate: resolvedMode == .full ? nil : MirageAudioConfiguration.aacBitrate(for: effectiveQuality, channelCount: channelCount(for: resolvedMode))
        )

        if resolvedMode == .full {
            config.quality = .high
            config.matchVideoQuality = false
            config.bitrate = nil
            config.channelLayout = .source
        }

        await startAudioStreaming(
            for: clientContext,
            config: config,
            streamKind: streamKind
        )
    }

    private func audioQualityForPreset(_ preset: MirageQualityPreset) -> MirageAudioQuality {
        switch preset {
        case .low: return .low
        case .medium: return .medium
        case .high: return .high
        case .ultra: return .high
        case .custom: return .medium
        }
    }

    private func channelCount(for mode: MirageAudioMode) -> Int {
        switch mode {
        case .mono: return 1
        case .stereo: return 2
        case .surround: return 6
        case .full: return 2
        case .off: return 0
        }
    }

    private func channelLayout(for mode: MirageAudioMode) -> MirageAudioChannelLayout {
        switch mode {
        case .mono: return .mono
        case .stereo: return .stereo
        case .surround: return .surround5_1
        case .full: return .source
        case .off: return .stereo
        }
    }

    private func startAudioStreaming(
        for clientContext: ClientContext,
        config: MirageAudioConfiguration,
        streamKind: AudioStreamKind
    ) async {
        activeAudioClientID = clientContext.client.id
        audioConfiguration = config
        audioStreamStartedSent = false
        audioStreamEpoch &+= 1
        audioSampleCount = 0
        audioPacketCount = 0
        audioLastEmptyLogTime = 0

        let encoder = AudioEncoder(baseConfiguration: config)
        audioEncoder = encoder

        if audioPacketSender == nil {
            audioPacketSender = AudioPacketSender(maxPacketSize: networkConfig.maxPacketSize)
        }
        audioPacketSender?.resetEpoch()

        guard let (streamID, context) = resolveAudioStreamContext(
            for: streamKind,
            clientID: clientContext.client.id
        ) else {
            MirageLogger.error(.host, "Audio stream context unavailable")
            return
        }

        if let audioStreamContextID, audioStreamContextID != streamID,
           let previousContext = streamsByID[audioStreamContextID] {
            await previousContext.setAudioSampleHandler(nil)
        }

        audioStreamContextID = streamID

        let handler: @Sendable (AudioSampleBuffer) -> Void = { [weak self] sampleBuffer in
            guard let self else { return }
            Task { @MainActor [weak self] in
                await self?.handleAudioSample(sampleBuffer, clientID: clientContext.client.id)
            }
        }

        await context.setAudioSampleHandler(handler)
        MirageLogger.host("Audio capture attached to stream \(streamID)")
    }

    private func resolveAudioStreamContext(
        for kind: AudioStreamKind,
        clientID: UUID
    ) -> (StreamID, StreamContext)? {
        switch kind {
        case .system:
            if let streamID = desktopStreamID, let context = desktopStreamContext {
                return (streamID, context)
            }
            if let session = activeStreams.first(where: { $0.client.id == clientID }),
               let context = streamsByID[session.id] {
                return (session.id, context)
            }
        case .app(let bundleIdentifier):
            if let session = activeStreams.first(where: {
                $0.client.id == clientID &&
                $0.window.application?.bundleIdentifier?.lowercased() == bundleIdentifier.lowercased()
            }),
               let context = streamsByID[session.id] {
                return (session.id, context)
            }
            if let streamID = desktopStreamID, let context = desktopStreamContext {
                return (streamID, context)
            }
            if let session = activeStreams.first(where: { $0.client.id == clientID }),
               let context = streamsByID[session.id] {
                return (session.id, context)
            }
        }
        return nil
    }

    private func handleAudioSample(_ sampleBuffer: AudioSampleBuffer, clientID: UUID) async {
        guard let encoder = audioEncoder,
              let packetSender = audioPacketSender else { return }

        if audioSampleCount == 0 {
            if let format = CMSampleBufferGetFormatDescription(sampleBuffer.buffer),
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format) {
                MirageLogger.host("Audio sample format: \(asbd.pointee.mSampleRate)Hz \(asbd.pointee.mChannelsPerFrame)ch")
            }
        }
        audioSampleCount &+= 1

        let frames = encoder.encode(sampleBuffer: sampleBuffer.buffer)
        guard let firstFrame = frames.first else {
            let now = CFAbsoluteTimeGetCurrent()
            if now - audioLastEmptyLogTime > 2.0 {
                let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer.buffer)
                MirageLogger.error(.host, "Audio encode produced no frames (samples=\(sampleCount))")
                audioLastEmptyLogTime = now
            }
            return
        }

        if audioConfiguration?.channelCount != firstFrame.config.channelCount ||
            audioConfiguration?.sampleRate != firstFrame.config.sampleRate ||
            audioConfiguration?.codec != firstFrame.config.codec ||
            audioConfiguration?.channelLayout != firstFrame.config.channelLayout {
            audioConfiguration = firstFrame.config
            audioStreamStartedSent = false
            audioStreamEpoch &+= 1
            packetSender.resetEpoch()
        }

        if !audioStreamStartedSent {
            await sendAudioStreamStarted(to: clientID, config: firstFrame.config)
            audioStreamStartedSent = true
        }

        for frame in frames {
            let packets = packetSender.packets(for: frame)
            if packets.isEmpty {
                let now = CFAbsoluteTimeGetCurrent()
                if now - audioLastEmptyLogTime > 2.0 {
                    MirageLogger.error(.host, "Audio packetization produced no packets")
                    audioLastEmptyLogTime = now
                }
            }
            for packet in packets {
                sendAudioPacket(data: packet, to: clientID)
                audioPacketCount &+= 1
                if audioPacketCount == 1 {
                    MirageLogger.host("Sent first audio packet (\(packet.count) bytes)")
                }
            }
        }
    }

    private func sendAudioStreamStarted(to clientID: UUID, config: MirageAudioConfiguration) async {
        guard let audioPort = currentAudioPortForStream() else { return }
        let message = AudioStreamStartedMessage(
            audioPort: audioPort,
            config: AudioConfigMessage(
                mode: config.mode,
                quality: config.quality,
                matchVideoQuality: config.matchVideoQuality,
                codec: config.codec,
                sampleRate: config.sampleRate,
                channelCount: config.channelCount,
                channelLayout: config.channelLayout,
                bitrate: config.bitrate
            )
        )

        guard let context = clientsByConnection.first(where: { $0.value.client.id == clientID })?.value else { return }
        do {
            try await context.send(.audioStreamStarted, content: message)
        } catch {
            MirageLogger.error(.host, "Failed to send audioStreamStarted: \(error)")
        }
    }

    private func currentAudioPortForStream() -> UInt16? {
        if case .advertising(_, _, let port) = state, port > 0 {
            return port
        }
        return nil
    }

    private func sendAudioPacket(data: Data, to clientID: UUID) {
        guard let connection = audioConnectionByClientID[clientID] else { return }
        connection.send(content: data, completion: .idempotent)
    }

    func stopAudioStreaming(reason: String) async {
        if let clientID = activeAudioClientID {
            let message = AudioStreamStoppedMessage(reason: reason)
            if let context = clientsByConnection.first(where: { $0.value.client.id == clientID })?.value {
                try? await context.send(.audioStreamStopped, content: message)
            }
        }

        audioStreamStartedSent = false
        audioConfiguration = nil
        audioEncoder = nil
        audioPacketSender = nil
        activeAudioClientID = nil
        audioSampleCount = 0
        audioPacketCount = 0
        audioLastEmptyLogTime = 0
        if let audioStreamContextID, let context = streamsByID[audioStreamContextID] {
            await context.setAudioSampleHandler(nil)
        }
        audioStreamContextID = nil
    }
}
#endif
