//
//  StreamContext+RateControlRetune.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/21/26.
//

import Foundation
import MirageKit

#if os(macOS)

extension StreamContext {
    private enum RateControlRetuneValidationStage: String, Sendable {
        case dynamicRetune
        case keyframeRetune
        case sessionRecreation
    }

    func scheduleRateControlRetuneValidation(
        previousBitrate: Int?,
        targetBitrate: Int?
    ) {
        guard let previousBitrate,
              let targetBitrate,
              targetBitrate > 0 else {
            rateControlRetuneValidationTask?.cancel()
            rateControlRetuneValidationResult = nil
            return
        }
        guard targetBitrate < previousBitrate else {
            rateControlRetuneValidationResult = "upward-retune-no-keyframe"
            return
        }

        rateControlRetuneValidationID &+= 1
        let validationID = rateControlRetuneValidationID
        let startTime = CFAbsoluteTimeGetCurrent()
        rateControlRetuneValidationResult = "dynamic-retune-pending"
        rateControlRetuneValidationTask?.cancel()
        rateControlRetuneValidationTask = Task(priority: .utility) { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            await self?.validateRateControlRetune(
                validationID: validationID,
                stage: .dynamicRetune,
                targetBitrate: targetBitrate,
                startTime: startTime
            )
        }
    }

    private func validateRateControlRetune(
        validationID: UInt64,
        stage: RateControlRetuneValidationStage,
        targetBitrate: Int,
        startTime: CFAbsoluteTime
    ) async {
        guard validationID == rateControlRetuneValidationID else { return }
        guard let encoder else {
            rateControlRetuneValidationResult = "\(stage.rawValue)-no-encoder"
            return
        }

        let snapshot = await encoder.encodedOutputSnapshot(since: startTime)
        guard isRateControlOvershooting(snapshot: snapshot, targetBitrate: targetBitrate) else {
            let measured = snapshot.actualBitrateBps.map(String.init) ?? "nil"
            rateControlRetuneValidationResult = "\(stage.rawValue)-validated-\(measured)"
            MirageLogger.stream(
                "Encoder rate-control retune validated: stage=\(stage.rawValue), target=\(targetBitrate), actual=\(measured)"
            )
            return
        }

        let actual = snapshot.actualBitrateBps ?? 0
        switch stage {
        case .dynamicRetune:
            keyframeForRetuneCount &+= 1
            rateControlRetuneValidationResult = "dynamic-retune-overshoot-keyframe-forced"
            MirageLogger.stream(
                "Encoder rate-control dynamic retune overshot target; forcing keyframe: target=\(targetBitrate), actual=\(actual)"
            )
            await encoder.forceKeyframe()
            scheduleRateControlRetuneValidationContinuation(
                validationID: validationID,
                stage: .keyframeRetune,
                targetBitrate: targetBitrate
            )

        case .keyframeRetune:
            encoderSessionRecreationCount &+= 1
            rateControlRetuneValidationResult = "keyframe-retune-overshoot-session-recreate"
            MirageLogger.stream(
                "Encoder rate-control keyframe retune overshot target; recreating VT session: target=\(targetBitrate), actual=\(actual)"
            )
            do {
                await packetSender?.bumpGeneration(reason: "rate-control retune session recreation")
                resetPipelineStateForReconfiguration(reason: "rate-control retune session recreation")
                try await encoder.recreateSessionForRateControlRetune()
                await encoder.forceKeyframe()
            } catch {
                MirageLogger.error(.stream, error: error, message: "Encoder rate-control session recreation failed: ")
                rateControlRetuneValidationResult = "session-recreation-failed"
                return
            }
            scheduleRateControlRetuneValidationContinuation(
                validationID: validationID,
                stage: .sessionRecreation,
                targetBitrate: targetBitrate
            )

        case .sessionRecreation:
            rateControlRetuneValidationResult = "session-recreation-overshoot-structural-adaptation-needed"
            MirageLogger.stream(
                "Encoder rate-control validation still overshot after session recreation: target=\(targetBitrate), actual=\(actual)"
            )
        }
    }

    private func scheduleRateControlRetuneValidationContinuation(
        validationID: UInt64,
        stage: RateControlRetuneValidationStage,
        targetBitrate: Int
    ) {
        let startTime = CFAbsoluteTimeGetCurrent()
        rateControlRetuneValidationTask?.cancel()
        rateControlRetuneValidationTask = Task(priority: .utility) { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            await self?.validateRateControlRetune(
                validationID: validationID,
                stage: stage,
                targetBitrate: targetBitrate,
                startTime: startTime
            )
        }
    }

    private func isRateControlOvershooting(
        snapshot: EncodedOutputTelemetrySnapshot,
        targetBitrate: Int
    ) -> Bool {
        guard let actualBitrate = snapshot.actualBitrateBps else { return false }
        let threshold = max(Double(targetBitrate) * 1.35, Double(targetBitrate + 3_000_000))
        return Double(actualBitrate) > threshold
    }
}

#endif
