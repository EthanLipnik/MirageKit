//
//  SharedVirtualDisplayManager+DisplayModeValidation.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/10/26.
//

import CoreGraphics
import Foundation
import MirageKit

#if os(macOS)
extension SharedVirtualDisplayManager {
    /// Converts physical pixels into logical points for the supplied display scale.
    static func logicalResolution(for pixelResolution: CGSize, scaleFactor: CGFloat = 2.0) -> CGSize {
        guard pixelResolution.width > 0, pixelResolution.height > 0 else { return pixelResolution }
        let scale = max(1.0, scaleFactor)
        return CGSize(
            width: pixelResolution.width / scale,
            height: pixelResolution.height / scale
        )
    }

    /// Conservative 1x fallback used when a Retina virtual-display mode cannot activate.
    static func fallbackResolution(for retinaResolution: CGSize) -> CGSize {
        let width = CGFloat(MirageStreamGeometry.alignedEncodedDimension(max(2.0, retinaResolution.width / 2.0)))
        let height = CGFloat(MirageStreamGeometry.alignedEncodedDimension(max(2.0, retinaResolution.height / 2.0)))
        return CGSize(width: width, height: height)
    }

    /// Normalizes virtual-display pixel sizes to the even dimensions expected by capture/encode.
    static func normalizedPixelResolution(_ resolution: CGSize) -> CGSize {
        CGSize(
            width: CGFloat(MirageStreamGeometry.alignedEncodedDimension(max(2.0, resolution.width))),
            height: CGFloat(MirageStreamGeometry.alignedEncodedDimension(max(2.0, resolution.height)))
        )
    }

    /// Whether the display should be re-enforced after the system reports it ready.
    static func needsPostReadyModeEnforcement(
        observedMode: ObservedDisplayMode?,
        expectedPixelResolution: CGSize,
        expectedRefreshRate: Double,
        pixelTolerance: CGFloat = 1.0,
        refreshTolerance: Double = 1.0
    ) -> Bool {
        guard let observedMode else { return true }

        let widthDelta = abs(observedMode.pixelResolution.width - expectedPixelResolution.width)
        let heightDelta = abs(observedMode.pixelResolution.height - expectedPixelResolution.height)
        guard widthDelta <= pixelTolerance, heightDelta <= pixelTolerance else {
            return true
        }

        return abs(observedMode.refreshRate - expectedRefreshRate) > refreshTolerance
    }

    /// Relative aspect-ratio delta between requested and candidate pixel sizes.
    static func aspectRelativeDelta(requested: CGSize, candidate: CGSize) -> CGFloat {
        guard requested.width > 0,
              requested.height > 0,
              candidate.width > 0,
              candidate.height > 0 else {
            return .greatestFiniteMagnitude
        }
        let requestedAspect = requested.width / requested.height
        let candidateAspect = candidate.width / candidate.height
        guard requestedAspect > 0, candidateAspect > 0 else {
            return .greatestFiniteMagnitude
        }
        return abs(requestedAspect - candidateAspect) / requestedAspect
    }

    /// Classifies whether observed display surfaces satisfy the requested mode.
    static func displayModeValidationAcceptance(
        snapshot: DisplayModeValidationSnapshot,
        expectedLogicalResolution: CGSize,
        expectedPixelResolution: CGSize,
        expectedRefreshRate: Double?
    ) -> DisplayModeValidationAcceptance? {
        let boundsReady = snapshot.boundsSize.width > 0 && snapshot.boundsSize.height > 0

        let scMatchesLogical = resolutionsMatch(snapshot.screenCaptureSize, expectedLogicalResolution)
        let scMatchesPixel = resolutionsMatch(snapshot.screenCaptureSize, expectedPixelResolution)
        let boundsMatchesLogical = resolutionsMatch(snapshot.boundsSize, expectedLogicalResolution)
        let boundsMatchesPixel = resolutionsMatch(snapshot.boundsSize, expectedPixelResolution)
        let modeMatchesLogical = resolutionsMatch(snapshot.modeLogicalSize, expectedLogicalResolution)
        let modeMatchesPixel = resolutionsMatch(snapshot.modePixelSize, expectedPixelResolution)

        let screenCaptureMatches = scMatchesLogical || scMatchesPixel
        let boundsMatches = boundsMatchesLogical || boundsMatchesPixel
        let observedSurfacesCoverExpectedGeometry = (scMatchesLogical || boundsMatchesLogical) &&
            (scMatchesPixel || boundsMatchesPixel)
        let sizeMatches = screenCaptureMatches || boundsMatches
        let modeMatches = modeMatchesLogical && modeMatchesPixel
        let modeSizeAvailable = snapshot.modeLogicalSize.width > 0 &&
            snapshot.modeLogicalSize.height > 0 &&
            snapshot.modePixelSize.width > 0 &&
            snapshot.modePixelSize.height > 0
        let modeRefreshRate = snapshot.modeRefreshRate ?? 0
        let modeRefreshAvailable = modeRefreshRate > 0
        let refreshMatches = if let expectedRefreshRate {
            modeRefreshAvailable && abs(modeRefreshRate - expectedRefreshRate) <= 1.0
        } else {
            true
        }
        let missingExpectedRefresh = expectedRefreshRate != nil && !modeRefreshAvailable
        let expectsOneX = resolutionsMatch(expectedLogicalResolution, expectedPixelResolution)

        if boundsReady, sizeMatches, modeMatches, refreshMatches {
            return .strict
        }

        if expectsOneX, boundsReady, sizeMatches, refreshMatches {
            return .lenientOneX
        }

        if expectsOneX, boundsReady, screenCaptureMatches, boundsMatches, missingExpectedRefresh {
            return .missingCoreGraphicsRefreshOneX
        }

        if boundsReady,
           observedSurfacesCoverExpectedGeometry,
           missingExpectedRefresh,
           !modeSizeAvailable || modeMatches {
            return .missingCoreGraphicsMode
        }

        return nil
    }

    /// Tolerance-based size equality for display validation.
    static func resolutionsMatch(_ lhs: CGSize, _ rhs: CGSize, tolerance: CGFloat = 1) -> Bool {
        abs(lhs.width - rhs.width) <= tolerance &&
            abs(lhs.height - rhs.height) <= tolerance
    }

    /// Current CoreGraphics mode sizes and refresh rate for a display.
    func observedDisplayMode(
        displayID: CGDirectDisplayID
    ) -> ObservedDisplayMode? {
        guard let modeSizes = CGVirtualDisplayBridge.currentDisplayModeSizes(displayID),
              let refreshRate = CGDisplayCopyDisplayMode(displayID)?.refreshRate else {
            return nil
        }
        return ObservedDisplayMode(
            logicalResolution: modeSizes.logical,
            pixelResolution: modeSizes.pixel,
            refreshRate: refreshRate
        )
    }

    /// Returns an observed mode only when it matches the requested pixel size and refresh rate.
    func validatedObservedDisplayMode(
        requestedResolution: CGSize,
        requestedRefreshRate: Int,
        observedMode: ObservedDisplayMode?
    ) -> ObservedDisplayMode? {
        guard let observedMode else { return nil }
        guard !needsResize(
            currentResolution: observedMode.pixelResolution,
            targetResolution: requestedResolution
        ) else {
            return nil
        }

        let refreshTolerance = 1.0
        guard abs(observedMode.refreshRate - Double(requestedRefreshRate)) <= refreshTolerance else {
            return nil
        }

        return observedMode
    }

    /// Waits for CoreGraphics and ScreenCaptureKit to agree that a display mode is usable.
    func validateDisplayMode(
        displayID: CGDirectDisplayID,
        expectedLogicalResolution: CGSize,
        expectedPixelResolution: CGSize,
        expectedRefreshRate: Double? = nil,
        startupBudget: DesktopVirtualDisplayStartupBudget? = nil
    )
    async -> DisplayValidationOutcome {
        guard expectedLogicalResolution.width > 0,
              expectedLogicalResolution.height > 0,
              expectedPixelResolution.width > 0,
              expectedPixelResolution.height > 0 else { return .ready }

        let maxAttempts = 6
        var delayMs = 80
        var sawScreenCaptureKitDelay = false

        for attempt in 1 ... maxAttempts {
            if startupBudget?.isExpired == true {
                return sawScreenCaptureKitDelay ? .screenCaptureKitVisibilityDelayed(displayID) : .modeMismatch
            }
            let bounds = CGDisplayBounds(displayID)
            let observedMode = observedDisplayMode(displayID: displayID)

            do {
                let scDisplay = try await findSCDisplay(
                    displayID: displayID,
                    maxAttempts: 1,
                    startupBudget: startupBudget
                )
                let scSize = CGSize(width: CGFloat(scDisplay.display.width), height: CGFloat(scDisplay.display.height))
                let modeLogicalSize = observedMode?.logicalResolution ?? .zero
                let modePixelSize = observedMode?.pixelResolution ?? .zero
                let modeRefreshRate = observedMode?.refreshRate
                let validationAcceptance = Self.displayModeValidationAcceptance(
                    snapshot: DisplayModeValidationSnapshot(
                        boundsSize: bounds.size,
                        screenCaptureSize: scSize,
                        modeLogicalSize: modeLogicalSize,
                        modePixelSize: modePixelSize,
                        modeRefreshRate: modeRefreshRate
                    ),
                    expectedLogicalResolution: expectedLogicalResolution,
                    expectedPixelResolution: expectedPixelResolution,
                    expectedRefreshRate: expectedRefreshRate
                )

                if validationAcceptance == .strict {
                    return .ready
                }

                if let validationAcceptance {
                    MirageLogger
                        .host(
                            "Virtual display \(displayID) accepted using \(validationAcceptance.logLabel) validation: " +
                                "bounds=\(bounds.size), sc=\(scDisplay.display.width)x\(scDisplay.display.height), " +
                                "modeLogical=\(modeLogicalSize), modePixel=\(modePixelSize), modeRefresh=\(modeRefreshRate ?? 0), " +
                                "expected=\(expectedPixelResolution)"
                        )
                    return .ready
                }

                MirageLogger
                    .host(
                        "Virtual display \(displayID) size mismatch (attempt \(attempt)/\(maxAttempts)): " +
                            "bounds=\(bounds.size), sc=\(scDisplay.display.width)x\(scDisplay.display.height), " +
                            "modeLogical=\(modeLogicalSize), modePixel=\(modePixelSize), modeRefresh=\(modeRefreshRate ?? 0), " +
                            "expectedLogical=\(expectedLogicalResolution), expectedPixel=\(expectedPixelResolution), expectedRefresh=\(expectedRefreshRate ?? 0)"
                    )
            } catch let error as SharedDisplayError {
                switch error {
                case .noActiveDisplay, .scDisplayNotFound:
                    sawScreenCaptureKitDelay = true
                default:
                    break
                }
                MirageLogger
                    .host(
                        "Virtual display \(displayID) size validation failed (attempt \(attempt)/\(maxAttempts)): \(error)"
                    )
            } catch {
                MirageLogger
                    .host(
                        "Virtual display \(displayID) size validation failed (attempt \(attempt)/\(maxAttempts)): \(error)"
                    )
            }

            if attempt < maxAttempts {
                let boundedDelayMs = startupBudget?.boundedDelayMilliseconds(delayMs) ?? delayMs
                do {
                    try await Task.sleep(for: .milliseconds(boundedDelayMs))
                } catch {
                    return .modeMismatch
                }
                delayMs = min(1000, Int(Double(delayMs) * 1.6))
            }
        }

        if sawScreenCaptureKitDelay {
            return .screenCaptureKitVisibilityDelayed(displayID)
        }
        return .modeMismatch
    }
}
#endif
