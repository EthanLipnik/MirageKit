//
//  CGVirtualDisplayBridge+Utilities.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Virtual display utility helpers.
//

import MirageKit
#if os(macOS)
import CoreGraphics
import Foundation

extension CGVirtualDisplayBridge {
    // MARK: - Display Utilities

    private static func expectedColorSpaceNames(for colorSpace: MirageColorSpace) -> Set<String> {
        switch colorSpace {
        case .displayP3:
            return [
                CGColorSpace.displayP3 as String,
                CGColorSpace.extendedDisplayP3 as String,
            ]
        case .sRGB:
            return [
                CGColorSpace.sRGB as String,
                CGColorSpace.extendedSRGB as String,
                CGColorSpace.linearSRGB as String,
            ]
        }
    }

    private static func propertyListData(_ propertyList: CFPropertyList?) -> Data? {
        guard let propertyList else { return nil }
        guard let data = CFPropertyListCreateData(
            kCFAllocatorDefault,
            propertyList,
            .binaryFormat_v1_0,
            0,
            nil
        ) else {
            return nil
        }
        return data.takeRetainedValue() as Data
    }

    struct DisplayModeSizes: Sendable {
        let logical: CGSize
        let pixel: CGSize
    }

    private static func sizeMatches(_ observed: CGSize, expected: CGSize, tolerance: CGFloat = 1.0) -> Bool {
        guard expected.width > 0, expected.height > 0 else { return false }
        let widthDelta = abs(observed.width - expected.width)
        let heightDelta = abs(observed.height - expected.height)
        return widthDelta <= tolerance && heightDelta <= tolerance
    }

    static func currentDisplayModeSizes(_ displayID: CGDirectDisplayID) -> DisplayModeSizes? {
        guard let mode = CGDisplayCopyDisplayMode(displayID) else { return nil }
        let logical = CGSize(width: CGFloat(mode.width), height: CGFloat(mode.height))
        let pixel = CGSize(width: CGFloat(mode.pixelWidth), height: CGFloat(mode.pixelHeight))
        return DisplayModeSizes(logical: logical, pixel: pixel)
    }

    /// Get the bounds of a display
    /// Note: CGDisplayBounds can return stale values for newly created virtual displays
    /// Prefer using the resolution from VirtualDisplayContext when available
    static func getDisplayBounds(_ displayID: CGDirectDisplayID) -> CGRect {
        CGDisplayBounds(displayID)
    }

    /// Wait for a virtual display to become online with non-zero bounds.
    /// Returns the observed bounds when ready, or nil on timeout.
    static func waitForDisplayReady(
        _ displayID: CGDirectDisplayID,
        expectedResolution: CGSize,
        alternateExpectedResolution: CGSize = .zero,
        timeout: TimeInterval = 4.0,
        pollInterval: TimeInterval = 0.05
    )
    async -> CGRect? {
        let deadline = Date().addingTimeInterval(timeout)
        var lastBounds = CGRect.zero

        while Date() < deadline {
            let online = isDisplayOnline(displayID)
            let bounds = CGDisplayBounds(displayID)
            lastBounds = bounds

            if online, bounds.width > 0, bounds.height > 0 {
                if expectedResolution.width > 0, expectedResolution.height > 0 {
                    let expectedPixel = alternateExpectedResolution.width > 0 && alternateExpectedResolution.height > 0
                        ? alternateExpectedResolution
                        : expectedResolution

                    if let modeSizes = currentDisplayModeSizes(displayID),
                       sizeMatches(modeSizes.logical, expected: expectedResolution),
                       sizeMatches(modeSizes.pixel, expected: expectedPixel) {
                        let origin = configuredDisplayOrigins[displayID] ?? bounds.origin
                        return CGRect(origin: origin, size: expectedResolution)
                    }

                    if sizeMatches(bounds.size, expected: expectedResolution) {
                        let origin = configuredDisplayOrigins[displayID] ?? bounds.origin
                        return CGRect(origin: origin, size: expectedResolution)
                    }
                } else {
                    return bounds
                }
            }

            let sleepMs = Int(max(10.0, pollInterval * 1000.0))
            try? await Task.sleep(for: .milliseconds(sleepMs))
        }

        let online = isDisplayOnline(displayID)
        if online, expectedResolution.width > 0, expectedResolution.height > 0 {
            let origin = configuredDisplayOrigins[displayID] ?? lastBounds.origin
            let fallbackBounds = CGRect(origin: origin, size: expectedResolution)
            MirageLogger
                .host(
                    "Display \(displayID) online but bounds invalid after wait; using known resolution \(fallbackBounds)"
                )
            return fallbackBounds
        }

        let timeoutText = timeout.formatted(.number.precision(.fractionLength(2)))
        MirageLogger.error(
            .host,
            "Display \(displayID) not ready after \(timeoutText)s (online: \(online), lastBounds: \(lastBounds))"
        )
        return nil
    }

    /// Get display bounds using known values (more reliable for virtual displays)
    /// CGDisplayBounds can return stale/incorrect values immediately after display creation
    /// for BOTH origin and size
    ///
    /// For window centering purposes, the virtual display is treated as starting at (0, 0).
    /// This is the coordinate space where windows will be positioned.
    static func getDisplayBounds(_ displayID: CGDirectDisplayID, knownResolution: CGSize) -> CGRect {
        // CGDisplayBounds is unreliable for newly created virtual displays, especially size.
        // If we have non-zero bounds, trust the reported size (points) to keep windows on-screen.
        let rawBounds = CGDisplayBounds(displayID)
        let origin = configuredDisplayOrigins[displayID] ?? rawBounds.origin

        if rawBounds.width > 0, rawBounds.height > 0 {
            let widthDelta = abs(rawBounds.width - knownResolution.width)
            let heightDelta = abs(rawBounds.height - knownResolution.height)
            if widthDelta <= 1, heightDelta <= 1 {
                return CGRect(origin: origin, size: rawBounds.size)
            }
            MirageLogger
                .host(
                    "getDisplayBounds(\(displayID)): raw size \(rawBounds.size) differs from knownResolution \(knownResolution) (origin \(origin))"
                )
        }

        // Fallback to known resolution when raw bounds are not available yet.
        let bounds = CGRect(origin: origin, size: knownResolution)
        MirageLogger
            .host(
                "getDisplayBounds(\(displayID)): using origin \(origin) with knownSize=\(knownResolution) (rawBounds=\(rawBounds)) -> \(bounds)"
            )
        return bounds
    }

    static func isDisplayOnline(_ displayID: CGDirectDisplayID) -> Bool {
        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &displayCount)
        guard displayCount > 0 else { return false }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetOnlineDisplayList(displayCount, &displays, &displayCount)
        return displays.contains(displayID)
    }

    static func displayColorSpaceValidation(
        displayID: CGDirectDisplayID,
        expectedColorSpace: MirageColorSpace
    ) -> (matches: Bool?, observedName: String?) {
        let observedColorSpace = CGDisplayCopyColorSpace(displayID)
        let expectedName: String = switch expectedColorSpace {
        case .displayP3:
            CGColorSpace.displayP3 as String
        case .sRGB:
            CGColorSpace.sRGB as String
        }
        guard let expectedCGColorSpace = CGColorSpace(name: expectedName as CFString) else {
            return (matches: nil, observedName: nil)
        }

        if let observedNameCF = observedColorSpace.name {
            let observedName = observedNameCF as String
            let matches = expectedColorSpaceNames(for: expectedColorSpace).contains(observedName)
            return (matches: matches, observedName: observedName)
        }

        if CFEqual(observedColorSpace, expectedCGColorSpace) {
            return (matches: true, observedName: "unnamed-equivalent")
        }

        if let observedICCData = observedColorSpace.copyICCData() as Data?,
           let expectedICCData = expectedCGColorSpace.copyICCData() as Data?,
           observedICCData == expectedICCData {
            return (matches: true, observedName: "icc-match")
        }

        if let observedPropertyListData = propertyListData(observedColorSpace.copyPropertyList()),
           let expectedPropertyListData = propertyListData(expectedCGColorSpace.copyPropertyList()),
           observedPropertyListData == expectedPropertyListData {
            return (matches: true, observedName: "property-list-match")
        }

        if observedColorSpace.model == .rgb {
            let observedWideGamut = observedColorSpace.isWideGamutRGB
            let expectedWideGamut = expectedColorSpace == .displayP3
            if observedWideGamut == expectedWideGamut {
                return (
                    matches: true,
                    observedName: observedWideGamut ? "wide-gamut-rgb" : "standard-gamut-rgb"
                )
            }
            return (
                matches: false,
                observedName: observedWideGamut ? "wide-gamut-rgb" : "standard-gamut-rgb"
            )
        }

        return (matches: nil, observedName: "unknown")
    }

    /// Returns true if the display is a Mirage-created virtual display.
    static func isMirageDisplay(_ displayID: CGDirectDisplayID) -> Bool {
        CGDisplayVendorNumber(displayID) == mirageVendorID &&
            CGDisplayModelNumber(displayID) == mirageProductID
    }

    /// Get the space ID for a display
    static func getSpaceForDisplay(_ displayID: CGDirectDisplayID) -> CGSSpaceID {
        CGSWindowSpaceBridge.getCurrentSpaceForDisplay(displayID)
    }
}
#endif
