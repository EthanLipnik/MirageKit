//
//  DesktopVirtualDisplayStartupAttempt.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/10/26.
//

import CoreGraphics
import Foundation
import MirageKit

#if os(macOS)
private let desktopVirtualDisplayStartupTargetDefaultsPrefix = "MirageDesktopVirtualDisplayStartupTarget.v1"

enum DesktopVirtualDisplayStartupTargetTier: String, Codable, Equatable {
    case preferred
    case degraded
}

enum DesktopVirtualDisplayStartupFallbackKind: Equatable {
    case primary
    case descriptorFallback
    case conservative
}

struct DesktopVirtualDisplayStartupAttempt: Equatable {
    let backingScale: DesktopBackingScaleResolution
    let refreshRate: Int
    let colorSpace: MirageColorSpace
    let label: String
    let fallbackKind: DesktopVirtualDisplayStartupFallbackKind
    let isConservativeRetry: Bool
    let isCachedTarget: Bool
    let targetTier: DesktopVirtualDisplayStartupTargetTier
}

struct DesktopVirtualDisplayStartupRequest: Equatable, Codable {
    let requestedPixelWidth: Int
    let requestedPixelHeight: Int
    let requestedRefreshRate: Int
    let requestedColorDepth: MirageStreamColorDepth
    let requestedColorSpace: MirageColorSpace
    let requestedHiDPI: Bool
}

struct DesktopVirtualDisplayStartupPlan: Equatable {
    let request: DesktopVirtualDisplayStartupRequest
    let attempts: [DesktopVirtualDisplayStartupAttempt]
}

private struct DesktopVirtualDisplayStartupCacheEntry: Equatable, Codable {
    let pixelWidth: Int
    let pixelHeight: Int
    let hiDPI: Bool
    let refreshRate: Int
    let colorSpace: MirageColorSpace
    let targetTier: DesktopVirtualDisplayStartupTargetTier
}

private func desktopVirtualDisplayStartupAttemptKey(
    _ attempt: DesktopVirtualDisplayStartupAttempt
) -> String {
    "\(Int(attempt.backingScale.pixelResolution.width))x\(Int(attempt.backingScale.pixelResolution.height))-\(attempt.backingScale.scaleFactor > 1.5 ? "retina" : "1x")-\(attempt.refreshRate)-\(attempt.colorSpace.rawValue)"
}

private func desktopVirtualDisplayStartupTargetDefaultsKey(
    for request: DesktopVirtualDisplayStartupRequest
) -> String {
    "\(desktopVirtualDisplayStartupTargetDefaultsPrefix)." +
        "\(request.requestedPixelWidth)x\(request.requestedPixelHeight)." +
        "hz=\(request.requestedRefreshRate)." +
        "depth=\(request.requestedColorDepth.rawValue)." +
        "color=\(request.requestedColorSpace.rawValue)." +
        "hidpi=\(request.requestedHiDPI ? 1 : 0)"
}

private func cachedDesktopVirtualDisplayStartupTarget(
    for request: DesktopVirtualDisplayStartupRequest
) -> DesktopVirtualDisplayStartupCacheEntry? {
    let key = desktopVirtualDisplayStartupTargetDefaultsKey(for: request)
    guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
    return try? JSONDecoder().decode(DesktopVirtualDisplayStartupCacheEntry.self, from: data)
}

func clearDesktopVirtualDisplayStartupTarget(
    for request: DesktopVirtualDisplayStartupRequest
) {
    let key = desktopVirtualDisplayStartupTargetDefaultsKey(for: request)
    UserDefaults.standard.removeObject(forKey: key)
}

func recordDesktopVirtualDisplayStartupTargetSuccess(
    _ attempt: DesktopVirtualDisplayStartupAttempt,
    for request: DesktopVirtualDisplayStartupRequest
) {
    guard attempt.targetTier == .preferred else {
        MirageLogger.host(
            "Not caching degraded desktop virtual display startup target \(attempt.label)"
        )
        return
    }
    recordDesktopVirtualDisplayStartupTargetSuccess(
        pixelResolution: attempt.backingScale.pixelResolution,
        scaleFactor: attempt.backingScale.scaleFactor,
        refreshRate: attempt.refreshRate,
        colorSpace: attempt.colorSpace,
        targetTier: attempt.targetTier,
        for: request
    )
}

func recordDesktopVirtualDisplayStartupTargetSuccess(
    pixelResolution: CGSize,
    scaleFactor: CGFloat,
    refreshRate: Int,
    colorSpace: MirageColorSpace,
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
        colorSpace: colorSpace,
        targetTier: targetTier
    )
    guard let data = try? JSONEncoder().encode(entry) else { return }
    let key = desktopVirtualDisplayStartupTargetDefaultsKey(for: request)
    UserDefaults.standard.set(data, forKey: key)
}

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
        isConservativeRetry: entry.targetTier == .degraded,
        isCachedTarget: true,
        targetTier: entry.targetTier
    )
}

func desktopVirtualDisplayStartupPlan(
    logicalResolution: CGSize,
    requestedScaleFactor: CGFloat,
    requestedRefreshRate: Int,
    requestedColorDepth: MirageStreamColorDepth,
    requestedColorSpace: MirageColorSpace
) -> DesktopVirtualDisplayStartupPlan {
    func prioritizedColorSpaces(requestedColorSpace: MirageColorSpace) -> [MirageColorSpace] {
        var ordered = [requestedColorSpace]
        for candidate in MirageColorSpace.allCases where candidate != requestedColorSpace {
            ordered.append(candidate)
        }
        return ordered
    }

    let primary = DesktopVirtualDisplayStartupAttempt(
        backingScale: resolvedDesktopBackingScaleResolution(
            logicalResolution: logicalResolution,
            defaultScaleFactor: requestedScaleFactor
        ),
        refreshRate: requestedRefreshRate,
        colorSpace: requestedColorSpace,
        label: "primary",
        fallbackKind: .primary,
        isConservativeRetry: false,
        isCachedTarget: false,
        targetTier: .preferred
    )

    let request = DesktopVirtualDisplayStartupRequest(
        requestedPixelWidth: Int(primary.backingScale.pixelResolution.width.rounded()),
        requestedPixelHeight: Int(primary.backingScale.pixelResolution.height.rounded()),
        requestedRefreshRate: requestedRefreshRate,
        requestedColorDepth: requestedColorDepth,
        requestedColorSpace: requestedColorSpace,
        requestedHiDPI: primary.backingScale.scaleFactor > 1.5
    )

    let conservative = DesktopVirtualDisplayStartupAttempt(
        backingScale: resolvedDesktopBackingScaleResolution(
            logicalResolution: logicalResolution,
            defaultScaleFactor: 1.0
        ),
        refreshRate: SharedVirtualDisplayManager.streamRefreshRate(for: requestedRefreshRate),
        colorSpace: .sRGB,
        label: "conservative-retry",
        fallbackKind: .conservative,
        isConservativeRetry: true,
        isCachedTarget: false,
        targetTier: .degraded
    )

    var attempts: [DesktopVirtualDisplayStartupAttempt] = []
    var seenAttemptKeys = Set<String>()

    func appendAttempt(_ attempt: DesktopVirtualDisplayStartupAttempt) {
        let key = desktopVirtualDisplayStartupAttemptKey(attempt)
        if seenAttemptKeys.insert(key).inserted {
            attempts.append(attempt)
        }
    }

    if let cachedTarget = cachedDesktopVirtualDisplayStartupTarget(for: request) {
        appendAttempt(cachedDesktopVirtualDisplayStartupAttempt(from: cachedTarget))
    }
    appendAttempt(primary)
    if requestedColorSpace != .sRGB {
        for candidateColorSpace in prioritizedColorSpaces(requestedColorSpace: requestedColorSpace)
            where candidateColorSpace != requestedColorSpace {
            appendAttempt(
                DesktopVirtualDisplayStartupAttempt(
                    backingScale: primary.backingScale,
                    refreshRate: primary.refreshRate,
                    colorSpace: candidateColorSpace,
                    label: "descriptor-fallback-\(candidateColorSpace.rawValue)",
                    fallbackKind: .descriptorFallback,
                    isConservativeRetry: false,
                    isCachedTarget: false,
                    targetTier: .degraded
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

func desktopVirtualDisplayStartupAttempts(
    logicalResolution: CGSize,
    requestedScaleFactor: CGFloat,
    requestedRefreshRate: Int,
    requestedColorDepth: MirageStreamColorDepth,
    requestedColorSpace: MirageColorSpace
) -> [DesktopVirtualDisplayStartupAttempt] {
    desktopVirtualDisplayStartupPlan(
        logicalResolution: logicalResolution,
        requestedScaleFactor: requestedScaleFactor,
        requestedRefreshRate: requestedRefreshRate,
        requestedColorDepth: requestedColorDepth,
        requestedColorSpace: requestedColorSpace
    ).attempts
}
#endif
