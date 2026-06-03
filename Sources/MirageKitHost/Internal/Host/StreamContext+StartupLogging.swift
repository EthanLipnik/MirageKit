//
//  StreamContext+StartupLogging.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/13/26.
//

import Foundation
import MirageKit

#if os(macOS)
extension StreamContext {
    func streamBoundaryLog(
        phase: String,
        kind: String,
        width: Int? = nil,
        height: Int? = nil
    ) -> String {
        let generation = packetSender?.currentGeneration ?? 0
        let qualityReferenceFrameRate = MirageBitrateQualityMapper.qualityReferenceFrameRate(
            for: currentFrameRate
        )
        let targetBitrate = encoderConfig.bitrate ?? 0
        let activeBitrate = currentTargetBitrateBps ?? targetBitrate
        let startupTargetBitrate = startupBitrate ?? targetBitrate
        let widthText = width.map { " width=\($0)" } ?? ""
        let heightText = height.map { " height=\($0)" } ?? ""

        return "event=stream_boundary phase=\(phase) side=host media=video kind=\(kind) " +
            "stream=\(streamID)\(widthText)\(heightText) epoch=\(epoch) generation=\(generation) " +
            "fpsCap=\(currentFrameRate) qualityRefFPS=\(qualityReferenceFrameRate) " +
            "startupTargetBitrate=\(startupTargetBitrate) targetBitrate=\(targetBitrate) " +
            "activeBitrate=\(activeBitrate) quality=\(Self.formattedBoundaryQuality(activeQuality)) " +
            "qualityFloor=\(Self.formattedBoundaryQuality(qualityFloor)) " +
            "qualityCeiling=\(Self.formattedBoundaryQuality(qualityCeiling)) " +
            "\(mediaPathDiagnosticSummary)"
    }

    private nonisolated static func formattedBoundaryQuality(_ quality: Float) -> String {
        quality.formatted(.number.precision(.fractionLength(3)))
    }

    /// Resets startup telemetry state for a new stream startup sequence.
    func setStartupBaseTime(_ baseTime: CFAbsoluteTime, label: String) {
        startupBaseTime = baseTime
        startupLabel = label
        startupFirstCaptureLogged = false
        startupFirstEncodeLogged = false
        startupRegistrationLogged = false
    }

    /// Logs a startup milestone relative to the active startup baseline.
    func logStartupEvent(_ event: String) {
        guard startupBaseTime > 0 else { return }
        let deltaMs = Int((CFAbsoluteTimeGetCurrent() - startupBaseTime) * 1000)
        let label = startupLabel.isEmpty ? "stream \(streamID)" : startupLabel
        MirageLogger.stream("\(label) start: \(event) (+\(deltaMs)ms)")
    }
}
#endif
