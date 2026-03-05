//
//  ClientAudioDecodePipeline.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/4/26.
//
//  Off-main audio ingest + jitter + decode sequencing for UDP audio packets.
//

import Foundation
import MirageKit

actor ClientAudioDecodePipeline {
    private let jitterBuffer: AudioJitterBuffer
    private let decoder: AudioDecoder

    init(startupBufferSeconds: Double = 0.150) {
        jitterBuffer = AudioJitterBuffer(startupBufferSeconds: startupBufferSeconds)
        decoder = AudioDecoder()
    }

    func reset() async {
        await jitterBuffer.reset()
        await decoder.reset()
    }

    func ingestPacket(
        header: AudioPacketHeader,
        payload: Data,
        targetChannelCount: Int
    ) async -> [DecodedPCMFrame] {
        let encodedFrames = await jitterBuffer.ingest(header: header, payload: payload)
        guard !encodedFrames.isEmpty else { return [] }

        let clampedTargetChannelCount = max(1, targetChannelCount)
        var decodedFrames: [DecodedPCMFrame] = []
        decodedFrames.reserveCapacity(encodedFrames.count)
        for encodedFrame in encodedFrames {
            guard let decodedFrame = await decoder.decode(
                encodedFrame,
                targetChannelCount: clampedTargetChannelCount
            ) else {
                continue
            }
            decodedFrames.append(decodedFrame)
        }
        return decodedFrames
    }
}
