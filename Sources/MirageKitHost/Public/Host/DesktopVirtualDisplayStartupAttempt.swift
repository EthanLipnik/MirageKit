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

struct DesktopVirtualDisplayStartupAttempt: Equatable {
    let backingScale: DesktopBackingScaleResolution
    let refreshRate: Int
    let colorSpace: MirageColorSpace
    let label: String
    let isConservativeRetry: Bool
    let isCachedTarget: Bool
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
    let entry = DesktopVirtualDisplayStartupCacheEntry(
        pixelWidth: Int(attempt.backingScale.pixelResolution.width.rounded()),
        pixelHeight: Int(attempt.backingScale.pixelResolution.height.rounded()),
        hiDPI: attempt.backingScale.scaleFactor > 1.5,
        refreshRate: attempt.refreshRate,
        colorSpace: attempt.colorSpace
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
        isConservativeRetry: !entry.hiDPI || entry.colorSpace != .displayP3 || entry.refreshRate <= 60,
        isCachedTarget: true
    )
}

func desktopVirtualDisplayStartupPlan(
    logicalResolution: CGSize,
    requestedScaleFactor: CGFloat,
    requestedRefreshRate: Int,
    requestedColorDepth: MirageStreamColorDepth,
    requestedColorSpace: MirageColorSpace
) -> DesktopVirtualDisplayStartupPlan {
    let primary = DesktopVirtualDisplayStartupAttempt(
        backingScale: resolvedDesktopBackingScaleResolution(
            logicalResolution: logicalResolution,
            defaultScaleFactor: requestedScaleFactor
        ),
        refreshRate: requestedRefreshRate,
        colorSpace: requestedColorSpace,
        label: "primary",
        isConservativeRetry: false,
        isCachedTarget: false
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
        refreshRate: SharedVirtualDisplayManager.streamRefreshRate(for: 60),
        colorSpace: .sRGB,
        label: "conservative-retry",
        isConservativeRetry: true,
        isCachedTarget: false
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
