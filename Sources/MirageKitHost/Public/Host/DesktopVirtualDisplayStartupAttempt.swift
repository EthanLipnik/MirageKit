//
//  DesktopVirtualDisplayStartupAttempt.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/10/26.
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

#if os(macOS)
private let desktopVirtualDisplayStartupTargetDefaultsPrefix = "MirageDesktopVirtualDisplayStartupTarget.v1"

/// Quality tier for a desktop virtual-display startup target.
enum DesktopVirtualDisplayStartupTargetTier: String, Codable, Equatable {
    case preferred
    case degraded
}

/// Fallback class represented by a desktop virtual-display startup attempt.
enum DesktopVirtualDisplayStartupFallbackKind: Equatable {
    case primary
    case descriptorFallback
    case conservative
}

/// One candidate display configuration in the desktop virtual-display startup ladder.
struct DesktopVirtualDisplayStartupAttempt: Equatable {
    let backingScale: DesktopBackingScaleResolution
    let refreshRate: Int
    let colorSpace: MirageMedia.MirageColorSpace
    let label: String
    let fallbackKind: DesktopVirtualDisplayStartupFallbackKind
    let isConservativeRetry: Bool
    let isCachedTarget: Bool

    /// Stable key used to remove duplicate display configurations from the startup ladder.
    fileprivate var deduplicationKey: String {
        let pixelWidth = Int(backingScale.pixelResolution.width)
        let pixelHeight = Int(backingScale.pixelResolution.height)
        let scaleLabel = backingScale.scaleFactor > 1.5 ? "retina" : "1x"
        return "\(pixelWidth)x\(pixelHeight)-\(scaleLabel)-\(refreshRate)-\(colorSpace.rawValue)"
    }
}

/// Stable key describing the display configuration requested by desktop startup.
struct DesktopVirtualDisplayStartupRequest: Equatable, Codable {
    let requestedLogicalWidth: Int
    let requestedLogicalHeight: Int
    let requestedPixelWidth: Int
    let requestedPixelHeight: Int
    let requestedRefreshRate: Int
    let requestedColorDepth: MirageMedia.MirageStreamColorDepth
    let requestedColorSpace: MirageMedia.MirageColorSpace
    let requestedHiDPI: Bool
    let requestedStreamScaleBasis: Int
}

/// Ordered desktop virtual-display startup attempts for one request.
struct DesktopVirtualDisplayStartupPlan: Equatable {
    let request: DesktopVirtualDisplayStartupRequest
    let attempts: [DesktopVirtualDisplayStartupAttempt]
}

/// Cached display target that previously satisfied a desktop startup request.
private struct DesktopVirtualDisplayStartupCacheEntry: Equatable, Codable {
    let pixelWidth: Int
    let pixelHeight: Int
    let hiDPI: Bool
    let refreshRate: Int
    let colorSpace: MirageMedia.MirageColorSpace
}

/// Returns the UserDefaults key for a cached startup target.
private func desktopVirtualDisplayStartupTargetDefaultsKey(
    for request: DesktopVirtualDisplayStartupRequest
) -> String {
    "\(desktopVirtualDisplayStartupTargetDefaultsPrefix)." +
        "\(request.requestedLogicalWidth)x\(request.requestedLogicalHeight)." +
        "\(request.requestedPixelWidth)x\(request.requestedPixelHeight)." +
        "hz=\(request.requestedRefreshRate)." +
        "depth=\(request.requestedColorDepth.rawValue)." +
        "color=\(request.requestedColorSpace.rawValue)." +
        "hidpi=\(request.requestedHiDPI ? 1 : 0)." +
        "streamScale=\(request.requestedStreamScaleBasis)"
}

/// Loads the cached preferred startup target for a request.
private func cachedDesktopVirtualDisplayStartupTarget(
    for request: DesktopVirtualDisplayStartupRequest
) -> DesktopVirtualDisplayStartupCacheEntry? {
    let key = desktopVirtualDisplayStartupTargetDefaultsKey(for: request)
    guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
    do {
        return try JSONDecoder().decode(DesktopVirtualDisplayStartupCacheEntry.self, from: data)
    } catch {
        MirageLogger.error(.host, error: error, message: "Failed to decode desktop virtual-display startup target: ")
        return nil
    }
}

/// Clears a cached startup target after it fails to satisfy a request.
func clearDesktopVirtualDisplayStartupTarget(
    for request: DesktopVirtualDisplayStartupRequest
) {
    let key = desktopVirtualDisplayStartupTargetDefaultsKey(for: request)
    UserDefaults.standard.removeObject(forKey: key)
}

/// Records a preferred startup target for reuse by future matching desktop streams.
func recordDesktopVirtualDisplayStartupTargetSuccess(
    pixelResolution: CGSize,
    scaleFactor: CGFloat,
    refreshRate: Int,
    colorSpace: MirageMedia.MirageColorSpace,
    targetTier: DesktopVirtualDisplayStartupTargetTier,
    for request: DesktopVirtualDisplayStartupRequest
) {
    guard targetTier == .preferred else {
        MirageLogger.host("Not caching degraded desktop virtual display startup result")
        return
    }
    let entry = DesktopVirtualDisplayStartupCacheEntry(
        pixelWidth: Int(pixelResolution.width.rounded()),
        pixelHeight: Int(pixelResolution.height.rounded()),
        hiDPI: scaleFactor > 1.5,
        refreshRate: refreshRate,
        colorSpace: colorSpace
    )
    let data: Data
    do {
        data = try JSONEncoder().encode(entry)
    } catch {
        MirageLogger.error(.host, error: error, message: "Failed to encode desktop virtual-display startup target: ")
        return
    }
    let key = desktopVirtualDisplayStartupTargetDefaultsKey(for: request)
    UserDefaults.standard.set(data, forKey: key)
}

/// Builds a startup attempt from a cached preferred target.
private func cachedDesktopVirtualDisplayStartupAttempt(
    from entry: DesktopVirtualDisplayStartupCacheEntry
) -> DesktopVirtualDisplayStartupAttempt {
    DesktopVirtualDisplayStartupAttempt(
        backingScale: DesktopBackingScaleResolution(
            scaleFactor: entry.hiDPI ? 2.0 : 1.0,
            pixelResolution: CGSize(width: entry.pixelWidth, height: entry.pixelHeight)
        ),
        refreshRate: entry.refreshRate,
        colorSpace: entry.colorSpace,
        label: "cached-target",
        fallbackKind: .primary,
        isConservativeRetry: false,
        isCachedTarget: true
    )
}

/// Builds the ordered fallback plan for desktop virtual-display startup.
func desktopVirtualDisplayStartupPlan(
    logicalResolution: CGSize,
    requestedScaleFactor: CGFloat,
    requestedRefreshRate: Int,
    requestedColorDepth: MirageMedia.MirageStreamColorDepth,
    requestedColorSpace: MirageMedia.MirageColorSpace,
    requestedStreamScale: CGFloat = 1.0
) -> DesktopVirtualDisplayStartupPlan {
    let normalizedLogicalResolution = MirageMedia.MirageStreamGeometry.normalizedLogicalSize(logicalResolution)
    let primary = DesktopVirtualDisplayStartupAttempt(
        backingScale: resolvedDesktopBackingScaleResolution(
            logicalResolution: normalizedLogicalResolution,
            defaultScaleFactor: requestedScaleFactor
        ),
        refreshRate: requestedRefreshRate,
        colorSpace: requestedColorSpace,
        label: "primary",
        fallbackKind: .primary,
        isConservativeRetry: false,
        isCachedTarget: false
    )

    let request = DesktopVirtualDisplayStartupRequest(
        requestedLogicalWidth: Int(normalizedLogicalResolution.width.rounded()),
        requestedLogicalHeight: Int(normalizedLogicalResolution.height.rounded()),
        requestedPixelWidth: Int(primary.backingScale.pixelResolution.width.rounded()),
        requestedPixelHeight: Int(primary.backingScale.pixelResolution.height.rounded()),
        requestedRefreshRate: requestedRefreshRate,
        requestedColorDepth: requestedColorDepth,
        requestedColorSpace: requestedColorSpace,
        requestedHiDPI: primary.backingScale.scaleFactor > 1.5,
        requestedStreamScaleBasis: Int((MirageMedia.MirageStreamGeometry.clampStreamScale(requestedStreamScale) * 1000).rounded())
    )

    let conservative = DesktopVirtualDisplayStartupAttempt(
        backingScale: resolvedDesktopBackingScaleResolution(
            logicalResolution: normalizedLogicalResolution,
            defaultScaleFactor: 1.0
        ),
        refreshRate: SharedVirtualDisplayManager.streamRefreshRate(for: requestedRefreshRate),
        colorSpace: .sRGB,
        label: "conservative-retry",
        fallbackKind: .conservative,
        isConservativeRetry: true,
        isCachedTarget: false
    )
    let retinaEquivalent = DesktopVirtualDisplayStartupAttempt(
        backingScale: DesktopBackingScaleResolution(
            scaleFactor: 2.0,
            pixelResolution: primary.backingScale.pixelResolution
        ),
        refreshRate: primary.refreshRate,
        colorSpace: primary.colorSpace,
        label: "retina-equivalent",
        fallbackKind: .primary,
        isConservativeRetry: false,
        isCachedTarget: false
    )
    let shouldPreferRetinaEquivalent = primary.backingScale.scaleFactor <= 1.5 &&
        (
            primary.backingScale.pixelResolution.width > 1920 ||
                primary.backingScale.pixelResolution.height > 1080
        )

    var attempts: [DesktopVirtualDisplayStartupAttempt] = []
    var seenAttemptKeys = Set<String>()

    func appendAttempt(_ attempt: DesktopVirtualDisplayStartupAttempt) {
        if seenAttemptKeys.insert(attempt.deduplicationKey).inserted {
            attempts.append(attempt)
        }
    }

    if let cachedTarget = cachedDesktopVirtualDisplayStartupTarget(for: request) {
        appendAttempt(cachedDesktopVirtualDisplayStartupAttempt(from: cachedTarget))
    }
    if shouldPreferRetinaEquivalent {
        appendAttempt(retinaEquivalent)
    }
    appendAttempt(primary)
    if requestedColorSpace != .sRGB {
        for candidateColorSpace in MirageMedia.MirageColorSpace.allCases where candidateColorSpace != requestedColorSpace {
            appendAttempt(
                DesktopVirtualDisplayStartupAttempt(
                    backingScale: primary.backingScale,
                    refreshRate: primary.refreshRate,
                    colorSpace: candidateColorSpace,
                    label: "descriptor-fallback-\(candidateColorSpace.rawValue)",
                    fallbackKind: .descriptorFallback,
                    isConservativeRetry: false,
                    isCachedTarget: false
                )
            )
        }
    }
    appendAttempt(conservative)

    return DesktopVirtualDisplayStartupPlan(
        request: request,
        attempts: attempts
    )
}

#endif
