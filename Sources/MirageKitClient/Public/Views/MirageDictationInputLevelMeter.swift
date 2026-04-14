//
//  MirageDictationInputLevelMeter.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/13/26.
//

import AVFAudio
import Foundation

final class MirageDictationInputLevelMeter: @unchecked Sendable {
    private struct State {
        var smoothedLevel: Float = 0
        var lastEmissionTime: CFAbsoluteTime?
    }

    private let floorDecibels: Float
    private let emissionInterval: CFTimeInterval
    private let attackSmoothingFactor: Float
    private let releaseSmoothingFactor: Float
    private let lock = NSLock()
    private var state = State()

    init(
        floorDecibels: Float = -50,
        emissionInterval: CFTimeInterval = 1.0 / 24.0,
        attackSmoothingFactor: Float = 0.55,
        releaseSmoothingFactor: Float = 0.18
    ) {
        self.floorDecibels = floorDecibels
        self.emissionInterval = emissionInterval
        self.attackSmoothingFactor = attackSmoothingFactor
        self.releaseSmoothingFactor = releaseSmoothingFactor
    }

    func process(_ buffer: AVAudioPCMBuffer, at time: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> Float? {
        process(normalizedLevel: Self.normalizedLevel(for: buffer, floorDecibels: floorDecibels), at: time)
    }

    func process(normalizedLevel: Float, at time: CFAbsoluteTime) -> Float? {
        let clampedLevel = min(max(normalizedLevel, 0), 1)

        lock.lock()
        defer { lock.unlock() }

        let smoothingFactor = if clampedLevel > state.smoothedLevel {
            attackSmoothingFactor
        } else {
            releaseSmoothingFactor
        }
        state.smoothedLevel += (clampedLevel - state.smoothedLevel) * smoothingFactor

        if let lastEmissionTime = state.lastEmissionTime,
           time - lastEmissionTime < emissionInterval {
            return nil
        }

        state.lastEmissionTime = time
        return state.smoothedLevel
    }

    @discardableResult
    func reset() -> Float {
        lock.lock()
        state = State()
        lock.unlock()
        return 0
    }

    static func normalizedLevel(
        for buffer: AVAudioPCMBuffer,
        floorDecibels: Float = -50
    ) -> Float {
        let meanSquare = meanSquareSampleValue(for: buffer)
        guard meanSquare > 0 else { return 0 }

        let rms = sqrt(meanSquare)
        let decibels = Float(20 * log10(rms))
        let clampedDecibels = min(max(decibels, floorDecibels), 0)
        return (clampedDecibels - floorDecibels) / abs(floorDecibels)
    }

    private static func meanSquareSampleValue(for buffer: AVAudioPCMBuffer) -> Double {
        let audioBufferList = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        var totalSquares = 0.0
        var totalSamples = 0

        for audioBuffer in audioBufferList {
            guard let audioData = audioBuffer.mData else { continue }

            switch buffer.format.commonFormat {
            case .pcmFormatFloat32:
                accumulateMeanSquare(
                    from: audioData.assumingMemoryBound(to: Float.self),
                    sampleCount: Int(audioBuffer.mDataByteSize) / MemoryLayout<Float>.stride,
                    scale: 1,
                    totalSquares: &totalSquares,
                    totalSamples: &totalSamples
                )
            case .pcmFormatFloat64:
                accumulateMeanSquare(
                    from: audioData.assumingMemoryBound(to: Double.self),
                    sampleCount: Int(audioBuffer.mDataByteSize) / MemoryLayout<Double>.stride,
                    scale: 1,
                    totalSquares: &totalSquares,
                    totalSamples: &totalSamples
                )
            case .pcmFormatInt16:
                accumulateMeanSquare(
                    from: audioData.assumingMemoryBound(to: Int16.self),
                    sampleCount: Int(audioBuffer.mDataByteSize) / MemoryLayout<Int16>.stride,
                    scale: Double(Int16.max),
                    totalSquares: &totalSquares,
                    totalSamples: &totalSamples
                )
            case .pcmFormatInt32:
                accumulateMeanSquare(
                    from: audioData.assumingMemoryBound(to: Int32.self),
                    sampleCount: Int(audioBuffer.mDataByteSize) / MemoryLayout<Int32>.stride,
                    scale: Double(Int32.max),
                    totalSquares: &totalSquares,
                    totalSamples: &totalSamples
                )
            default:
                continue
            }
        }

        guard totalSamples > 0 else { return 0 }
        return totalSquares / Double(totalSamples)
    }

    private static func accumulateMeanSquare<Sample: BinaryInteger>(
        from pointer: UnsafePointer<Sample>,
        sampleCount: Int,
        scale: Double,
        totalSquares: inout Double,
        totalSamples: inout Int
    ) {
        guard sampleCount > 0 else { return }
        let samples = UnsafeBufferPointer(start: pointer, count: sampleCount)

        for sample in samples {
            let normalized = Double(Int64(sample)) / scale
            totalSquares += normalized * normalized
        }
        totalSamples += sampleCount
    }

    private static func accumulateMeanSquare<Sample: BinaryFloatingPoint>(
        from pointer: UnsafePointer<Sample>,
        sampleCount: Int,
        scale: Double,
        totalSquares: inout Double,
        totalSamples: inout Int
    ) {
        guard sampleCount > 0 else { return }
        let samples = UnsafeBufferPointer(start: pointer, count: sampleCount)

        for sample in samples {
            let normalized = Double(sample) / scale
            totalSquares += normalized * normalized
        }
        totalSamples += sampleCount
    }
}
