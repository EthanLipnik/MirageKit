//
//  CGVirtualDisplayBridge+ModeValidation.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

import CoreGraphics
import Foundation
import MirageKit

#if os(macOS)
import AppKit

// MARK: - Mode Validation

extension CGVirtualDisplayBridge {
    /// Applies a virtual display mode and verifies that CoreGraphics reports the requested logical and pixel geometry.
    ///
    /// Private virtual-display APIs can acknowledge settings before the display pipeline has converged, so creation
    /// and resize paths share this polling validator before accepting the display as usable.
    static func activateAndValidateMode(
        display: AnyObject,
        settingsClass: NSObject.Type,
        modeClass: NSObject.Type,
        pixelWidth: Int,
        pixelHeight: Int,
        refreshRate: Double,
        hiDPI: Bool,
        serial: UInt32?,
        startupBudget: DesktopVirtualDisplayStartupBudget?
    )
    -> Bool {
        let requestedLogical = CGSize(
            width: hiDPI ? pixelWidth / 2 : pixelWidth,
            height: hiDPI ? pixelHeight / 2 : pixelHeight
        )
        let requestedPixel = CGSize(width: pixelWidth, height: pixelHeight)

        let transferFunctionCandidates = transferFunctionAttempts()
        for attempt in modeActivationAttempts(pixelWidth: pixelWidth, pixelHeight: pixelHeight, hiDPI: hiDPI) {
            for transferFunction in transferFunctionCandidates {
                if startupBudget?.isExpired == true { return false }
                guard let displayMode = createDisplayMode(
                    modeClass: modeClass,
                    width: attempt.modeWidth,
                    height: attempt.modeHeight,
                    refreshRate: refreshRate,
                    transferFunction: transferFunction.code
                ) else { continue }

                let settings = settingsClass.init()
                settings.setValue([displayMode], forKey: "modes")
                settings.setValue(attempt.hiDPISetting, forKey: "hiDPI")

                let appliedTransferFunction = modeTransferFunction(displayMode).map(String.init) ?? "unknown"
                MirageLogger.host(
                    "Applying virtual display mode attempt \(attempt.label): mode=\(attempt.modeWidth)x\(attempt.modeHeight)@\(refreshRate)Hz, hiDPISetting=\(attempt.hiDPISetting), transferFunction=\(transferFunction.label), modeReadback=\(appliedTransferFunction)"
                )

                guard applySettings(settings, to: display) else {
                    logVirtualDisplaySettingsProbeFailure(
                        attemptLabel: attempt.label,
                        transferFunctionLabel: transferFunction.label
                    )
                    continue
                }

                guard let displayID = (display as AnyObject).value(forKey: "displayID") as? CGDirectDisplayID, displayID != 0 else {
                    MirageLogger.error(.host, "Virtual display has invalid displayID after attempt \(attempt.label)")
                    continue
                }

                if validateModeActivation(
                    displayID: displayID,
                    requestedLogical: requestedLogical,
                    requestedPixel: requestedPixel,
                    hiDPISetting: attempt.hiDPISetting,
                    serial: serial,
                    startupBudget: startupBudget
                ) {
                    MirageLogger.host(
                        "Virtual display mode activation succeeded with attempt \(attempt.label) and transferFunction=\(transferFunction.label)"
                    )
                    return true
                }
            }
        }

        return false
    }

    static func teardownFailedDisplay(displayID: CGDirectDisplayID, profileLabel: String) -> Bool {
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            if !isDisplayOnline(displayID) {
                configuredDisplayOrigins.removeValue(forKey: displayID)
                return true
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        configuredDisplayOrigins.removeValue(forKey: displayID)
        MirageLogger.host("Virtual display \(displayID) still online after profile \(profileLabel) failure; marking as orphan for cleanup")

        // Register this display as orphaned so the next acquisition attempt
        // force-invalidates it instead of blocking on a stale display.
        Task {
            await SharedVirtualDisplayManager.shared.trackOrphanedDisplay(displayID)
        }
        return false
    }

    static func modeValidationLogLine(
        displayID: CGDirectDisplayID,
        serial: UInt32?,
        hiDPISetting: UInt32,
        requestedLogical: CGSize,
        requestedPixel: CGSize,
        observed: DisplayModeSizes?,
        observedBounds: CGRect,
        observedPixelDimensions: CGSize,
        sawOnline: Bool
    )
    -> String {
        let observedLogical = observed?.logical ?? .zero
        let observedPixel = observed?.pixel ?? .zero
        let scale = observedLogical.width > 0 ? observedPixel.width / observedLogical.width : 0
        let scaleText = Double(scale).formatted(.number.precision(.fractionLength(2)))
        let serialText = serial.map(String.init) ?? "unknown"
        return "Virtual display mode validation failed: displayID=\(displayID), serial=\(serialText), hiDPISetting=\(hiDPISetting), requestedLogical=\(requestedLogical), requestedPixel=\(requestedPixel), observedLogical=\(observedLogical), observedPixel=\(observedPixel), observedScale=\(scaleText)x, observedBounds=\(observedBounds.size), observedPixelDimensions=\(observedPixelDimensions), online=\(sawOnline)"
    }

    static func approximatelyMatches(
        _ observed: CGSize,
        expected: CGSize,
        tolerance: CGFloat = 1.0
    )
    -> Bool {
        abs(observed.width - expected.width) <= tolerance &&
            abs(observed.height - expected.height) <= tolerance
    }

    static func relativeDelta(observed: CGFloat, expected: CGFloat) -> CGFloat {
        guard expected > 0 else { return .infinity }
        return abs(observed - expected) / expected
    }

    static func isAcceptableOneXFallbackForRetinaRequest(
        requestedLogical: CGSize,
        requestedPixel: CGSize,
        observedLogical: CGSize,
        observedPixel: CGSize,
        observedBounds: CGRect,
        observedPixelDimensions: CGSize,
        isOnline: Bool
    ) -> Bool {
        guard isOnline else { return false }

        let requestedScale = requestedLogical.width > 0 ? requestedPixel.width / requestedLogical.width : 0
        guard requestedScale > 1.5 else { return false }

        let pixelMatches = approximatelyMatches(observedPixel, expected: requestedPixel) ||
            approximatelyMatches(observedPixelDimensions, expected: requestedPixel)
        guard pixelMatches else { return false }

        let logicalCollapsedToPixel = approximatelyMatches(observedLogical, expected: requestedPixel) ||
            approximatelyMatches(observedBounds.size, expected: requestedPixel)
        guard logicalCollapsedToPixel else { return false }

        let observedScale: CGFloat = if observedLogical.width > 0 {
            observedPixel.width / observedLogical.width
        } else if observedBounds.width > 0 {
            observedPixelDimensions.width / observedBounds.width
        } else {
            0
        }
        return abs(observedScale - 1.0) <= retinaQuantizedScaleTolerance
    }

    static func validateModeActivation(
        displayID: CGDirectDisplayID,
        requestedLogical: CGSize,
        requestedPixel: CGSize,
        hiDPISetting: UInt32,
        serial: UInt32?,
        startupBudget: DesktopVirtualDisplayStartupBudget?
    )
    -> Bool {
        guard startupBudget?.isExpired != true else { return false }
        let validationTimeout = startupBudget?.boundedTimeout(1.6) ?? 1.6
        let deadline = Date().addingTimeInterval(validationTimeout)
        var lastObserved: DisplayModeSizes?
        var lastBounds = CGRect.zero
        var lastPixelDimensions = CGSize.zero
        var sawOnline = false
        var grossMismatchPollCount = 0
        var grossMismatchFirstObservedAt: CFAbsoluteTime = 0

        while Date() < deadline {
            if startupBudget?.isExpired == true { break }
            let pollNow = CFAbsoluteTimeGetCurrent()
            let isOnline = isDisplayOnline(displayID)
            sawOnline = sawOnline || isOnline

            let bounds = CGDisplayBounds(displayID)
            if bounds.width > 0, bounds.height > 0 {
                lastBounds = bounds
            }

            let pixelDimensions = CGSize(
                width: CGFloat(CGDisplayPixelsWide(displayID)),
                height: CGFloat(CGDisplayPixelsHigh(displayID))
            )
            if pixelDimensions.width > 0, pixelDimensions.height > 0 {
                lastPixelDimensions = pixelDimensions
            }

            if let observed = currentDisplayModeSizes(displayID),
               observed.logical.width > 0,
               observed.logical.height > 0,
               observed.pixel.width > 0,
               observed.pixel.height > 0 {
                lastObserved = observed

                let logicalMatches = abs(observed.logical.width - requestedLogical.width) <= 1 &&
                    abs(observed.logical.height - requestedLogical.height) <= 1
                let pixelMatches = abs(observed.pixel.width - requestedPixel.width) <= 1 &&
                    abs(observed.pixel.height - requestedPixel.height) <= 1

                if logicalMatches, pixelMatches {
                    let scale = observed.logical.width > 0 ? observed.pixel.width / observed.logical.width : 0
                    let scaleText = Double(scale).formatted(.number.precision(.fractionLength(2)))
                    MirageLogger.host(
                        "Virtual display mode active: logical=\(observed.logical), pixel=\(observed.pixel), scale=\(scaleText)x"
                    )
                    return true
                }

                if isGrossRetinaModeMismatch(
                    requestedLogical: requestedLogical,
                    requestedPixel: requestedPixel,
                    observedLogical: observed.logical,
                    observedPixel: observed.pixel,
                    hiDPISetting: hiDPISetting
                ) {
                    grossMismatchPollCount += 1
                    if grossMismatchFirstObservedAt == 0 {
                        grossMismatchFirstObservedAt = pollNow
                    }
                    let grossMismatchDuration = pollNow - grossMismatchFirstObservedAt
                    if grossMismatchPollCount >= grossRetinaMismatchPollThreshold ||
                        grossMismatchDuration >= grossRetinaMismatchAbortSeconds {
                        MirageLogger.host(
                            "Virtual display Retina validation aborted early after gross mismatch: requestedLogical=\(requestedLogical), requestedPixel=\(requestedPixel), observedLogical=\(observed.logical), observedPixel=\(observed.pixel), polls=\(grossMismatchPollCount)"
                        )
                        break
                    }
                } else {
                    grossMismatchPollCount = 0
                    grossMismatchFirstObservedAt = 0
                }

                if hiDPISetting == hiDPIEnabledSetting {
                    let observedScale = observed.logical.width > 0 ? observed.pixel.width / observed.logical.width : 0
                    let requestedScale = requestedLogical.width > 0 ? requestedPixel.width / requestedLogical.width : 0

                    let logicalWidthDelta = relativeDelta(observed: observed.logical.width, expected: requestedLogical.width)
                    let logicalHeightDelta = relativeDelta(observed: observed.logical.height, expected: requestedLogical.height)
                    let pixelWidthDelta = relativeDelta(observed: observed.pixel.width, expected: requestedPixel.width)
                    let pixelHeightDelta = relativeDelta(observed: observed.pixel.height, expected: requestedPixel.height)
                    let scaleDelta = relativeDelta(observed: observedScale, expected: requestedScale)

                    if logicalWidthDelta <= retinaQuantizedRelativeTolerance,
                       logicalHeightDelta <= retinaQuantizedRelativeTolerance,
                       pixelWidthDelta <= retinaQuantizedRelativeTolerance,
                       pixelHeightDelta <= retinaQuantizedRelativeTolerance,
                       scaleDelta <= retinaQuantizedScaleTolerance {
                        let observedScaleText = Double(observedScale).formatted(.number.precision(.fractionLength(2)))
                        MirageLogger.host(
                            "Virtual display mode accepted with quantized Retina validation: requestedLogical=\(requestedLogical), requestedPixel=\(requestedPixel), observedLogical=\(observed.logical), observedPixel=\(observed.pixel), observedScale=\(observedScaleText)x"
                        )
                        return true
                    }

                    if isAcceptableOneXFallbackForRetinaRequest(
                        requestedLogical: requestedLogical,
                        requestedPixel: requestedPixel,
                        observedLogical: observed.logical,
                        observedPixel: observed.pixel,
                        observedBounds: bounds,
                        observedPixelDimensions: pixelDimensions,
                        isOnline: isOnline
                    ) {
                        let observedScaleText = Double(observedScale).formatted(
                            .number.precision(.fractionLength(2))
                        )
                        MirageLogger.host(
                            "Virtual display mode accepted with stable 1x fallback for Retina request: requestedLogical=\(requestedLogical), requestedPixel=\(requestedPixel), observedLogical=\(observed.logical), observedPixel=\(observed.pixel), observedScale=\(observedScaleText)x"
                        )
                        return true
                    }
                }
            } else {
                lastObserved = nil
                grossMismatchPollCount = 0
                grossMismatchFirstObservedAt = 0
            }

            // Some hosts keep CGDisplayCopyDisplayMode unset during 1x fallback bring-up.
            // If display geometry is stable and online, allow the 1x path to proceed.
            if hiDPISetting == hiDPIDisabledSetting, isOnline {
                let boundsMatch = bounds.width > 0 &&
                    bounds.height > 0 &&
                    approximatelyMatches(bounds.size, expected: requestedLogical)
                let pixelMatch = pixelDimensions.width > 0 &&
                    pixelDimensions.height > 0 &&
                    approximatelyMatches(pixelDimensions, expected: requestedPixel)

                if boundsMatch || pixelMatch {
                    MirageLogger.host(
                        "Virtual display mode accepted with lenient 1x validation: bounds=\(bounds.size), pixelDimensions=\(pixelDimensions), requested=\(requestedPixel)"
                    )
                    return true
                }
            }

            Thread.sleep(forTimeInterval: min(0.05, startupBudget?.remainingTimeInterval ?? 0.05))
        }

        MirageLogger.host(
            modeValidationLogLine(
                displayID: displayID,
                serial: serial,
                hiDPISetting: hiDPISetting,
                requestedLogical: requestedLogical,
                requestedPixel: requestedPixel,
                observed: lastObserved,
                observedBounds: lastBounds,
                observedPixelDimensions: lastPixelDimensions,
                sawOnline: sawOnline
            )
        )
        return false
    }
}


#endif
