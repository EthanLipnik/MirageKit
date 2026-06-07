//
//  MirageHostCaptureBenchmarkSourceResolution.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//
//  ScreenCaptureKit source resolution for host capture benchmarks.
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
import CoreGraphics
import Foundation
import ScreenCaptureKit

#if os(macOS)
@MainActor
extension MirageHostService {
    /// Resolves the prepared benchmark window to stable ScreenCaptureKit source objects.
    func resolveBenchmarkSource(
        _ preparedSource: MirageHostCaptureBenchmarkPreparedSource,
        fallbackDisplayID: CGDirectDisplayID,
        maxAttempts: Int = 12,
        initialDelayMs: Int = 80
    ) async throws -> MirageHostCaptureBenchmarkResolvedSource {
        let attempts = max(1, maxAttempts)
        var delayMs = max(40, initialDelayMs)
        var settledObservationCount = 0
        var lastFailureReason = "Benchmark source window \(preparedSource.windowID) did not surface in ScreenCaptureKit."

        for attempt in 1 ... attempts {
            do {
                let content = try await currentCaptureShareableContent()

                if let resolvedWindow = content.windows.first(where: { $0.windowID == preparedSource.windowID }),
                   let resolvedApplication = content.applications.first(where: {
                       $0.processID == preparedSource.applicationPID
                   }) ?? resolvedWindow.owningApplication,
                   let targetDisplay = content.displays.first(where: {
                       $0.displayID == preparedSource.displayID
                   }) ?? content.displays.first(where: {
                       $0.displayID == fallbackDisplayID
                   }) {
                    let resolvedDisplay = resolveDisplayForBenchmarkSourceWindow(
                        resolvedWindow,
                        displays: content.displays
                    ) ?? targetDisplay
                    if let geometryMismatchReason = benchmarkSourceGeometryMismatchReason(
                        preparedSource: preparedSource,
                        resolvedWindow: resolvedWindow,
                        resolvedDisplayID: resolvedDisplay.displayID
                    ) {
                        settledObservationCount = 0
                        lastFailureReason = geometryMismatchReason
                    } else {
                        settledObservationCount += 1
                        if settledObservationCount >= 2 || attempts == 1 {
                            return MirageHostCaptureBenchmarkResolvedSource(
                                windowWrapper: SCWindowWrapper(window: resolvedWindow),
                                applicationWrapper: SCApplicationWrapper(application: resolvedApplication),
                                displayWrapper: SCDisplayWrapper(display: resolvedDisplay),
                                sourceClock: preparedSource.sourceClock
                            )
                        }
                        lastFailureReason =
                            "Benchmark source window geometry is still settling at \(benchmarkFrameDescription(resolvedWindow.frame))."
                    }
                } else {
                    settledObservationCount = 0
                    lastFailureReason =
                        "Benchmark source window \(preparedSource.windowID) did not surface in ScreenCaptureKit."
                }

                if attempt < attempts {
                    try await Task.sleep(for: .milliseconds(Int64(delayMs)))
                    delayMs = min(500, Int(Double(delayMs) * 1.5))
                }
            } catch {
                settledObservationCount = 0
                lastFailureReason =
                    "Benchmark source window \(preparedSource.windowID) did not surface in ScreenCaptureKit."
                if attempt >= attempts {
                    throw MirageHostCaptureBenchmarkError.measurementInvalid(
                        lastFailureReason
                    )
                }
                try await Task.sleep(for: .milliseconds(Int64(delayMs)))
                delayMs = min(500, Int(Double(delayMs) * 1.5))
            }
        }

        throw MirageHostCaptureBenchmarkError.measurementInvalid(
            lastFailureReason
        )
    }

    /// Returns why a resolved source window does not match the prepared benchmark geometry.
    func benchmarkSourceGeometryMismatchReason(
        preparedSource: MirageHostCaptureBenchmarkPreparedSource,
        resolvedWindow: SCWindow,
        resolvedDisplayID: CGDirectDisplayID
    ) -> String? {
        if resolvedDisplayID != preparedSource.displayID {
            return "Benchmark source window surfaced on display \(resolvedDisplayID) instead of \(preparedSource.displayID)."
        }

        if let expectedWindowFrame = preparedSource.expectedWindowFrame,
           !captureBenchmarkSourceFrameMatchesExpected(
               expectedFrame: expectedWindowFrame,
               actualFrame: resolvedWindow.frame
           ) {
            return "Benchmark source window geometry did not settle. Expected \(benchmarkFrameDescription(expectedWindowFrame)), observed \(benchmarkFrameDescription(resolvedWindow.frame))."
        }

        return nil
    }

    /// Formats a window frame for benchmark diagnostics.
    func benchmarkFrameDescription(_ frame: CGRect) -> String {
        let originX = Int(frame.origin.x.rounded())
        let originY = Int(frame.origin.y.rounded())
        let width = Int(frame.width.rounded())
        let height = Int(frame.height.rounded())
        return "\(width)x\(height)@(\(originX),\(originY))"
    }

    /// Chooses the display that contains or best intersects a benchmark source window.
    func resolveDisplayForBenchmarkSourceWindow(
        _ window: SCWindow,
        displays: [SCDisplay]
    ) -> SCDisplay? {
        guard !displays.isEmpty else { return nil }

        let windowFrame = window.frame
        let windowCenter = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
        if let containingDisplay = displays.first(where: { $0.frame.contains(windowCenter) }) {
            return containingDisplay
        }

        var bestDisplay: SCDisplay?
        var bestIntersectionArea: CGFloat = 0
        for display in displays {
            let intersection = display.frame.intersection(windowFrame)
            let area = max(0, intersection.width) * max(0, intersection.height)
            if area > bestIntersectionArea {
                bestIntersectionArea = area
                bestDisplay = display
            }
        }

        return bestDisplay ?? displays.first
    }
}

#endif
