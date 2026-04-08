//
//  DesktopVirtualDisplayResizeTarget.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/7/26.
//

import CoreGraphics
import Foundation
import MirageKit

#if os(macOS)
private let desktopVirtualDisplayResizeTargetDefaultsPrefix = "MirageDesktopVirtualDisplayResizeTarget.v1"

struct DesktopVirtualDisplayResizeRequest: Equatable, Codable {
    let requestedPixelWidth: Int
    let requestedPixelHeight: Int
    let requestedRefreshRate: Int
    let requestedColorSpace: MirageColorSpace
    let requestedHiDPI: Bool
}

struct DesktopVirtualDisplayResizeCacheEntry: Equatable, Codable {
    let pixelWidth: Int
    let pixelHeight: Int
    let hiDPI: Bool
    let refreshRate: Int
    let colorSpace: MirageColorSpace
    let targetTier: DesktopVirtualDisplayStartupTargetTier
}

func desktopVirtualDisplayResizeRequest(
    pixelResolution: CGSize,
    refreshRate: Int,
    hiDPI: Bool,
    colorSpace: MirageColorSpace
) -> DesktopVirtualDisplayResizeRequest {
    DesktopVirtualDisplayResizeRequest(
        requestedPixelWidth: Int(pixelResolution.width.rounded()),
        requestedPixelHeight: Int(pixelResolution.height.rounded()),
        requestedRefreshRate: refreshRate,
        requestedColorSpace: colorSpace,
        requestedHiDPI: hiDPI
    )
}

private func desktopVirtualDisplayResizeTargetDefaultsKey(
    for request: DesktopVirtualDisplayResizeRequest
) -> String {
    "\(desktopVirtualDisplayResizeTargetDefaultsPrefix)." +
        "\(request.requestedPixelWidth)x\(request.requestedPixelHeight)." +
        "hz=\(request.requestedRefreshRate)." +
        "color=\(request.requestedColorSpace.rawValue)." +
        "hidpi=\(request.requestedHiDPI ? 1 : 0)"
}

func cachedDesktopVirtualDisplayResizeTarget(
    for request: DesktopVirtualDisplayResizeRequest
) -> DesktopVirtualDisplayResizeCacheEntry? {
    let key = desktopVirtualDisplayResizeTargetDefaultsKey(for: request)
    guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
    return try? JSONDecoder().decode(DesktopVirtualDisplayResizeCacheEntry.self, from: data)
}

func clearDesktopVirtualDisplayResizeTarget(
    for request: DesktopVirtualDisplayResizeRequest
) {
    let key = desktopVirtualDisplayResizeTargetDefaultsKey(for: request)
    UserDefaults.standard.removeObject(forKey: key)
}

func recordDesktopVirtualDisplayResizeTargetSuccess(
    pixelResolution: CGSize,
    scaleFactor: CGFloat,
    refreshRate: Int,
    colorSpace: MirageColorSpace,
    targetTier: DesktopVirtualDisplayStartupTargetTier,
    for request: DesktopVirtualDisplayResizeRequest
) {
    guard targetTier == .preferred else {
        MirageLogger.host("Not caching degraded desktop resize target")
        return
    }

    let entry = DesktopVirtualDisplayResizeCacheEntry(
        pixelWidth: Int(pixelResolution.width.rounded()),
        pixelHeight: Int(pixelResolution.height.rounded()),
        hiDPI: scaleFactor > 1.5,
        refreshRate: refreshRate,
        colorSpace: colorSpace,
        targetTier: targetTier
    )
    guard let data = try? JSONEncoder().encode(entry) else { return }
    let key = desktopVirtualDisplayResizeTargetDefaultsKey(for: request)
    UserDefaults.standard.set(data, forKey: key)
}

func recordDesktopVirtualDisplayResizeTargetSuccess(
    snapshot: SharedVirtualDisplayManager.DisplaySnapshot,
    for request: DesktopVirtualDisplayResizeRequest
) {
    let effectiveTier: DesktopVirtualDisplayStartupTargetTier = if Int(snapshot.resolution.width.rounded()) == request.requestedPixelWidth,
                                                                   Int(snapshot.resolution.height.rounded()) == request.requestedPixelHeight,
                                                                   Int(snapshot.refreshRate.rounded()) == request.requestedRefreshRate,
                                                                   snapshot.colorSpace == request.requestedColorSpace,
                                                                   (snapshot.scaleFactor > 1.5) == request.requestedHiDPI {
        .preferred
    } else {
        .degraded
    }

    recordDesktopVirtualDisplayResizeTargetSuccess(
        pixelResolution: snapshot.resolution,
        scaleFactor: snapshot.scaleFactor,
        refreshRate: Int(snapshot.refreshRate.rounded()),
        colorSpace: snapshot.colorSpace,
        targetTier: effectiveTier,
        for: request
    )
}
#endif
