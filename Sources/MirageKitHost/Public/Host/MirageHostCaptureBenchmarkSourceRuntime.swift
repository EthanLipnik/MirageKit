//
//  MirageHostCaptureBenchmarkSourceRuntime.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/14/26.
//

import CoreGraphics
import Foundation

#if os(macOS)

@_spi(HostApp)
public struct MirageHostCaptureBenchmarkSourceMeasurement: Sendable, Equatable {
    public let observedFPS: Double?
    public let frameCount: UInt64
    public let durationSeconds: Double

    public init(
        observedFPS: Double?,
        frameCount: UInt64,
        durationSeconds: Double
    ) {
        self.observedFPS = observedFPS
        self.frameCount = frameCount
        self.durationSeconds = durationSeconds
    }
}

@_spi(HostApp)
@MainActor
public final class MirageHostCaptureBenchmarkSourceRuntime {
    private let sampleChangeThreshold: CGFloat = 0.25

    private var measurementActive = false
    private var frameCount: UInt64 = 0
    private var lastAcceptedTimestamp: CFTimeInterval?
    private var lastPresentationSample: CGPoint?

    public init() {}

    public func beginMeasurement() {
        measurementActive = true
        frameCount = 0
        lastAcceptedTimestamp = nil
        lastPresentationSample = nil
    }

    public func cancelMeasurement() {
        measurementActive = false
        frameCount = 0
        lastAcceptedTimestamp = nil
        lastPresentationSample = nil
    }

    public func completeMeasurement(
        durationSeconds: Double
    ) -> MirageHostCaptureBenchmarkSourceMeasurement {
        let clampedDuration = max(0.001, durationSeconds)
        let observedFPS = Double(frameCount) / clampedDuration
        measurementActive = false
        lastAcceptedTimestamp = nil
        lastPresentationSample = nil
        return MirageHostCaptureBenchmarkSourceMeasurement(
            observedFPS: frameCount > 0 ? observedFPS : nil,
            frameCount: frameCount,
            durationSeconds: clampedDuration
        )
    }

    public func recordPresentationSample(
        timestamp: CFTimeInterval,
        samplePoint: CGPoint?
    ) {
        guard measurementActive else { return }

        let shouldCount: Bool
        if let samplePoint {
            if let lastPresentationSample {
                let deltaX = samplePoint.x - lastPresentationSample.x
                let deltaY = samplePoint.y - lastPresentationSample.y
                shouldCount = hypot(deltaX, deltaY) >= sampleChangeThreshold
            } else {
                shouldCount = true
            }
            lastPresentationSample = samplePoint
        } else {
            let minimumTimestampStep = 0.000_1
            if let lastAcceptedTimestamp {
                shouldCount = timestamp > lastAcceptedTimestamp + minimumTimestampStep
            } else {
                shouldCount = true
            }
        }

        guard shouldCount else { return }
        frameCount &+= 1
        lastAcceptedTimestamp = timestamp
    }
}

#endif
