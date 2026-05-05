//
//  StreamContext+ReceiverFeedback.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/5/26.
//
//  Receiver media feedback and host-owned adaptation.
//

import Foundation
import MirageKit

#if os(macOS)
extension StreamContext {
    func recordReceiverMediaFeedback(_ feedback: ReceiverMediaFeedbackMessage) async {
        guard feedback.streamID == streamID else { return }
        realtimeMediaSession.recordFeedback(feedback)
        let now = CFAbsoluteTimeGetCurrent()
        let action = realtimeAdaptationController.decide(
            input: HostRealtimeAdaptationInput(
                feedback: feedback,
                currentBitrate: encoderConfig.bitrate,
                activeQuality: activeQuality,
                qualityFloor: qualityFloor,
                colorDepth: encoderConfig.colorDepth,
                streamScale: streamScale,
                currentFrameRate: currentFrameRate
            ),
            now: now
        )
        await applyRealtimeAdaptationAction(action)
    }

    private func applyRealtimeAdaptationAction(_ action: HostRealtimeAdaptationAction) async {
        switch action {
        case .hold:
            return

        case let .reduceBitrate(bitrate, reason):
            do {
                try await updateEncoderSettings(
                    colorDepth: nil,
                    bitrate: bitrate,
                    updateRequestedTargetBitrate: false
                )
                realtimeMediaSession.recordAdaptation(reason: "bitrate:\(reason)")
                MirageLogger.metrics(
                    "Receiver feedback reduced bitrate for stream \(streamID) to \(bitrate)bps reason=\(reason)"
                )
            } catch {
                MirageLogger.error(.stream, error: error, message: "Failed to apply receiver bitrate adaptation: ")
            }

        case let .reduceQuality(quality, reason):
            let clamped = max(qualityFloor, min(qualityCeiling, quality))
            guard clamped < activeQuality else { return }
            activeQuality = clamped
            await encoder?.updateQuality(clamped)
            realtimeMediaSession.recordAdaptation(reason: "quality:\(reason)")
            MirageLogger.metrics(
                "Receiver feedback reduced quality for stream \(streamID) to " +
                    "\(clamped.formatted(.number.precision(.fractionLength(2)))) reason=\(reason)"
            )

        case let .reduceColorDepth(colorDepth, reason):
            do {
                try await updateEncoderSettings(
                    colorDepth: colorDepth,
                    bitrate: nil,
                    updateRequestedTargetBitrate: false
                )
                realtimeMediaSession.recordAdaptation(reason: "color-depth:\(reason)")
                MirageLogger.metrics(
                    "Receiver feedback reduced color depth for stream \(streamID) to \(colorDepth.displayName) reason=\(reason)"
                )
            } catch {
                MirageLogger.error(.stream, error: error, message: "Failed to apply receiver color-depth adaptation: ")
            }

        case let .reduceResolutionScale(scale, reason):
            do {
                try await updateStreamScale(scale)
                realtimeMediaSession.recordAdaptation(reason: "resolution:\(reason)")
                MirageLogger.metrics(
                    "Receiver feedback reduced stream scale for stream \(streamID) to " +
                        "\(Double(scale).formatted(.number.precision(.fractionLength(2)))) reason=\(reason)"
                )
            } catch {
                MirageLogger.error(.stream, error: error, message: "Failed to apply receiver resolution adaptation: ")
            }

        case let .reduceFrameRate(frameRate, reason):
            do {
                try await updateFrameRate(frameRate)
                realtimeMediaSession.recordAdaptation(reason: "fps:\(reason)")
                MirageLogger.metrics(
                    "Receiver feedback reduced frame rate for stream \(streamID) to \(frameRate)fps reason=\(reason)"
                )
            } catch {
                MirageLogger.error(.stream, error: error, message: "Failed to apply receiver frame-rate adaptation: ")
            }
        }
    }
}
#endif
