//
//  MirageDictationInputLevelMeterTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/13/26.
//

import AVFAudio
import Testing
@testable import MirageKitClient

struct MirageDictationInputLevelMeterTests {
    @Test("Silence produces zero normalized input level")
    func silenceProducesZeroNormalizedInputLevel() {
        let silenceBuffer = makeFloatBuffer(sampleValue: 0)

        let level = MirageDictationInputLevelMeter.normalizedLevel(for: silenceBuffer)

        #expect(level == 0)
    }

    @Test("Louder samples produce a higher normalized input level")
    func louderSamplesProduceHigherNormalizedLevel() {
        let quietBuffer = makeFloatBuffer(sampleValue: 0.08)
        let loudBuffer = makeFloatBuffer(sampleValue: 0.75)

        let quietLevel = MirageDictationInputLevelMeter.normalizedLevel(for: quietBuffer)
        let loudLevel = MirageDictationInputLevelMeter.normalizedLevel(for: loudBuffer)

        #expect(loudLevel > quietLevel)
    }

    @Test("Normalized input level always stays within zero and one")
    func normalizedInputLevelClampsToSupportedRange() {
        let overdrivenBuffer = makeFloatBuffer(sampleValue: 2.0)

        let level = MirageDictationInputLevelMeter.normalizedLevel(for: overdrivenBuffer)

        #expect(level >= 0)
        #expect(level <= 1)
    }

    @Test("Reset returns the reported level to zero")
    func resetReturnsReportedLevelToZero() {
        let meter = MirageDictationInputLevelMeter(
            emissionInterval: 0,
            attackSmoothingFactor: 1,
            releaseSmoothingFactor: 1
        )
        let loudBuffer = makeFloatBuffer(sampleValue: 0.9)

        let emittedLevel = meter.process(loudBuffer, at: 0)
        let resetLevel = meter.reset()
        let postResetLevel = meter.process(normalizedLevel: 0, at: 1)

        #expect(emittedLevel != nil)
        #expect((emittedLevel ?? 0) > 0)
        #expect(resetLevel == 0)
        #expect(postResetLevel == 0)
    }

    private func makeFloatBuffer(sampleValue: Float, frameCount: AVAudioFrameCount = 64) -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1) else {
            fatalError("Failed to create test audio format.")
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            fatalError("Failed to create test PCM buffer.")
        }
        buffer.frameLength = frameCount

        guard let channelData = buffer.floatChannelData else {
            fatalError("Expected float channel data for test PCM buffer.")
        }

        let samples = UnsafeMutableBufferPointer(start: channelData.pointee, count: Int(frameCount))
        for index in samples.indices {
            samples[index] = sampleValue
        }
        return buffer
    }
}
