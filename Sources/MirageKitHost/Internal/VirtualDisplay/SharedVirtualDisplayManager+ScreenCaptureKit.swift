//
//  SharedVirtualDisplayManager+ScreenCaptureKit.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Shared virtual display manager extensions.
//

import CoreGraphics
import Foundation
import MirageKit

#if os(macOS)
import ScreenCaptureKit

extension SharedVirtualDisplayManager {
    // MARK: - ScreenCaptureKit Integration

    /// Find the SCDisplay corresponding to the shared virtual display
    func findSCDisplay(
        maxAttempts: Int = 8,
        startupBudget: DesktopVirtualDisplayStartupBudget? = nil,
        expectedPixelResolution: CGSize? = nil
    )
    async throws -> SCDisplayWrapper {
        guard let displayID = sharedDisplay?.displayID else { throw SharedDisplayError.noActiveDisplay }
        return try await findSCDisplay(
            displayID: displayID,
            maxAttempts: maxAttempts,
            startupBudget: startupBudget,
            expectedPixelResolution: expectedPixelResolution ?? sharedDisplay?.resolution
        )
    }

    /// Find the SCDisplay for a specific displayID.
    func findSCDisplay(
        displayID: CGDirectDisplayID,
        maxAttempts: Int = 8,
        startupBudget: DesktopVirtualDisplayStartupBudget? = nil,
        expectedPixelResolution: CGSize? = nil
    )
    async throws -> SCDisplayWrapper {
        var attempt = 0
        var delayMs = 120
        var lastObservedResolution: CGSize?

        while attempt < maxAttempts {
            try startupBudget?.checkAvailable()
            attempt += 1

            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

                if let scDisplay = content.displays.first(where: { $0.displayID == displayID }) {
                    let observedResolution = CGSize(
                        width: CGFloat(scDisplay.width),
                        height: CGFloat(scDisplay.height)
                    )
                    let expectedLogicalResolution = expectedPixelResolution.flatMap {
                        Self.expectedLogicalSCDisplayResolution(
                            displayID: displayID,
                            expectedPixelResolution: $0
                        )
                    }
                    if let expectedPixelResolution,
                       !Self.scDisplayResolutionMatches(
                           observed: observedResolution,
                           expected: expectedPixelResolution,
                           expectedLogical: expectedLogicalResolution
                       ) {
                        lastObservedResolution = observedResolution
                        if attempt < maxAttempts {
                            MirageLogger.host(
                                "SCDisplay \(displayID) surfaced with stale size " +
                                    "\(Int(observedResolution.width))x\(Int(observedResolution.height)); " +
                                    "expected \(Int(expectedPixelResolution.width))x\(Int(expectedPixelResolution.height)) " +
                                    "(attempt \(attempt)/\(maxAttempts)); retrying in \(delayMs)ms"
                            )
                            let boundedDelayMs = startupBudget?.boundedDelayMilliseconds(delayMs) ?? delayMs
                            try? await Task.sleep(for: .milliseconds(boundedDelayMs))
                            delayMs = min(1000, Int(Double(delayMs) * 1.6))
                            continue
                        }
                        MirageLogger.host(
                            "SCDisplay \(displayID) size mismatch after \(maxAttempts) attempts: " +
                                "observed \(Int(observedResolution.width))x\(Int(observedResolution.height)), " +
                                "expected \(Int(expectedPixelResolution.width))x\(Int(expectedPixelResolution.height))"
                        )
                        throw SharedDisplayError.scDisplaySizeMismatch(
                            displayID: displayID,
                            observed: observedResolution,
                            expected: expectedPixelResolution
                        )
                    }
                    MirageLogger
                        .host(
                            "Found SCDisplay \(displayID): \(scDisplay.width)x\(scDisplay.height) (attempt \(attempt)/\(maxAttempts))"
                        )
                    return SCDisplayWrapper(display: scDisplay)
                }

                let available = content.displays.map(\.displayID)
                if attempt < maxAttempts {
                    MirageLogger
                        .host(
                            "SCDisplay not yet available for displayID \(displayID) (attempt \(attempt)/\(maxAttempts)); " +
                            "available: \(available); retrying in \(delayMs)ms"
                        )
                    let boundedDelayMs = startupBudget?.boundedDelayMilliseconds(delayMs) ?? delayMs
                    try? await Task.sleep(for: .milliseconds(boundedDelayMs))
                    delayMs = min(1000, Int(Double(delayMs) * 1.6))
                } else {
                    MirageLogger.host(
                        "SCDisplay not found for displayID \(displayID) after \(maxAttempts) attempts. Available: \(available)"
                    )
                }
            } catch let error as SharedDisplayError {
                throw error
            } catch {
                if attempt < maxAttempts {
                    MirageLogger.host(
                        "Failed to query SCShareableContent for displayID \(displayID) (attempt \(attempt)/\(maxAttempts)): \(error)"
                    )
                    let boundedDelayMs = startupBudget?.boundedDelayMilliseconds(delayMs) ?? delayMs
                    try? await Task.sleep(for: .milliseconds(boundedDelayMs))
                    delayMs = min(1000, Int(Double(delayMs) * 1.6))
                    continue
                }
                throw error
            }
        }

        if let expectedPixelResolution, let lastObservedResolution {
            throw SharedDisplayError.scDisplaySizeMismatch(
                displayID: displayID,
                observed: lastObservedResolution,
                expected: expectedPixelResolution
            )
        }
        throw SharedDisplayError.scDisplayNotFound(displayID)
    }

    static func scDisplayResolutionMatches(
        observed: CGSize,
        expected: CGSize,
        expectedLogical: CGSize? = nil,
        tolerance: CGFloat = 1.0
    )
    -> Bool {
        if resolutionMatches(observed, expected, tolerance: tolerance) {
            return true
        }
        if let expectedLogical,
           expectedLogical.width > 0,
           expectedLogical.height > 0,
           resolutionMatches(observed, expectedLogical, tolerance: tolerance) {
            return true
        }
        return false
    }

    private static func expectedLogicalSCDisplayResolution(
        displayID: CGDirectDisplayID,
        expectedPixelResolution: CGSize,
        tolerance: CGFloat = 1.0
    )
    -> CGSize? {
        guard let modeSizes = CGVirtualDisplayBridge.currentDisplayModeSizes(displayID),
              resolutionMatches(modeSizes.pixel, expectedPixelResolution, tolerance: tolerance),
              modeSizes.logical.width > 0,
              modeSizes.logical.height > 0,
              !resolutionMatches(modeSizes.logical, modeSizes.pixel, tolerance: tolerance) else {
            return nil
        }
        return modeSizes.logical
    }

    private static func resolutionMatches(
        _ observed: CGSize,
        _ expected: CGSize,
        tolerance: CGFloat
    )
    -> Bool {
        abs(observed.width - expected.width) <= tolerance &&
            abs(observed.height - expected.height) <= tolerance
    }

    /// Find the SCDisplay for the main display (used for login display streaming).
    func findMainSCDisplay() async throws -> SCDisplayWrapper {
        let mainDisplayID = CGMainDisplayID()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        guard let scDisplay = content.displays.first(where: { $0.displayID == mainDisplayID }) else {
            MirageLogger.host(
                "Main SCDisplay not found for displayID \(mainDisplayID). Available: \(content.displays.map(\.displayID))"
            )
            throw SharedDisplayError.scDisplayNotFound(mainDisplayID)
        }

        MirageLogger.host("Found main SCDisplay \(mainDisplayID): \(scDisplay.width)x\(scDisplay.height)")
        return SCDisplayWrapper(display: scDisplay)
    }
}
#endif
