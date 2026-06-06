//
//  CaptureStreamOutput+Cadence.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import CoreMedia
import Foundation

#if os(macOS)
import ScreenCaptureKit

// MARK: - Cadence Admission

extension CaptureStreamOutput {
    /// Decides whether a renderable ScreenCaptureKit sample should be admitted for the configured target cadence.
    ///
    /// Idle frames bypass cadence dropping so window state changes can still propagate when the source is otherwise quiet.
    nonisolated static func cadenceDecision(
        originPresentationTime: Double?,
        lastAdmittedSlotIndex: Int64,
        presentationTime: Double,
        targetFrameRate: Double,
        isIdleFrame: Bool,
        earlyToleranceFloor: Double = 0.001,
        earlyToleranceFraction: Double = 0.20
    ) -> CadenceDecision {
        guard !isIdleFrame else {
            return CadenceDecision(
                shouldDrop: false,
                originPresentationTime: originPresentationTime,
                admittedSlotIndex: lastAdmittedSlotIndex,
                expectedPresentationTime: nil
            )
        }
        guard targetFrameRate > 0 else {
            return CadenceDecision(
                shouldDrop: false,
                originPresentationTime: originPresentationTime,
                admittedSlotIndex: lastAdmittedSlotIndex,
                expectedPresentationTime: nil
            )
        }
        guard presentationTime.isFinite, presentationTime >= 0 else {
            return CadenceDecision(
                shouldDrop: false,
                originPresentationTime: originPresentationTime,
                admittedSlotIndex: lastAdmittedSlotIndex,
                expectedPresentationTime: nil
            )
        }

        let expectedInterval = 1.0 / targetFrameRate
        guard expectedInterval > 0 else {
            return CadenceDecision(
                shouldDrop: false,
                originPresentationTime: originPresentationTime,
                admittedSlotIndex: lastAdmittedSlotIndex,
                expectedPresentationTime: nil
            )
        }

        let resolvedOriginPresentationTime = originPresentationTime ?? presentationTime
        let tolerance = max(earlyToleranceFloor, expectedInterval * max(0.0, earlyToleranceFraction))
        let slotProgress = (presentationTime - resolvedOriginPresentationTime + tolerance) / expectedInterval
        let slotIndex = Int64(floor(max(0.0, slotProgress)))
        let expectedPresentationTime = resolvedOriginPresentationTime + (Double(slotIndex) * expectedInterval)

        if slotIndex <= lastAdmittedSlotIndex {
            return CadenceDecision(
                shouldDrop: true,
                originPresentationTime: resolvedOriginPresentationTime,
                admittedSlotIndex: lastAdmittedSlotIndex,
                expectedPresentationTime: expectedPresentationTime
            )
        }

        return CadenceDecision(
            shouldDrop: false,
            originPresentationTime: resolvedOriginPresentationTime,
            admittedSlotIndex: slotIndex,
            expectedPresentationTime: expectedPresentationTime
        )
    }

    func logAdmissionDrop() {
        poolLogLock.withLock {
            admissionDropCount += 1
            admissionDropTotalCount &+= 1
        }
    }

    func shouldDropForTargetCadence(
        cadenceTimestamp: Double,
        captureTime: CFAbsoluteTime,
        isIdleFrame: Bool
    )
    -> Bool {
        expectationLock.withLock {
            let resolvedPresentationTime: Double = if cadenceTimestamp.isFinite, cadenceTimestamp >= 0 {
                cadenceTimestamp
            } else {
                captureTime
            }
            let originPresentationTime: Double? = cadenceOriginPresentationTime > 0
                ? cadenceOriginPresentationTime
                : nil
            let decision = Self.cadenceDecision(
                originPresentationTime: originPresentationTime,
                lastAdmittedSlotIndex: lastCadenceAdmittedSlotIndex,
                presentationTime: resolvedPresentationTime,
                targetFrameRate: targetFrameRate,
                isIdleFrame: isIdleFrame
            )

            if decision.shouldDrop {
                return true
            }

            if !isIdleFrame, targetFrameRate > 0 {
                if let expectedPresentationTime = decision.expectedPresentationTime {
                    let skewMs = abs(resolvedPresentationTime - expectedPresentationTime) * 1000.0
                    cadenceSkewTotalMs += skewMs
                    cadenceSkewSampleCount += 1
                }
                cadencePassCount += 1
                cadenceOriginPresentationTime = decision.originPresentationTime ?? 0
                lastCadenceAdmittedSlotIndex = decision.admittedSlotIndex
            }
            return false
        }
    }

    func resolvedCadenceTimestamp(
        presentationTime: CMTime,
        attachments: [SCStreamFrameInfo: Any]?,
        captureTime: CFAbsoluteTime
    ) -> Double {
        if let displayTimeSeconds = resolvedDisplayTimeSeconds(from: attachments) {
            return displayTimeSeconds
        }
        let presentationSeconds = CMTimeGetSeconds(presentationTime)
        if presentationSeconds.isFinite, presentationSeconds >= 0 {
            return presentationSeconds
        }
        return captureTime
    }

    func resolvedDisplayTimeSeconds(
        from attachments: [SCStreamFrameInfo: Any]?
    ) -> Double? {
        guard let attachments,
              let rawValue = attachments[.displayTime] else {
            return nil
        }

        let hostTime: UInt64? = if let value = rawValue as? UInt64 {
            value
        } else if let value = rawValue as? NSNumber {
            value.uint64Value
        } else if let value = rawValue as? Int {
            UInt64(max(0, value))
        } else {
            nil
        }

        guard let hostTime, hostTime > 0 else {
            return nil
        }

        let hostTimeCM = CMClockMakeHostTimeFromSystemUnits(hostTime)
        let seconds = CMTimeGetSeconds(hostTimeCM)
        guard seconds.isFinite, seconds >= 0 else {
            return nil
        }
        return seconds
    }

    func logCadenceDrop() {
        poolLogLock.withLock {
            cadenceDropCount += 1
            cadenceDropTotalCount &+= 1
            cadenceMetrics.recordCadenceDrop()
        }
    }
}

#endif
