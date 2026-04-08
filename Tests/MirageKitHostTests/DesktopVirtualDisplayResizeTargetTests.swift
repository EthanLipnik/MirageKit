//
//  DesktopVirtualDisplayResizeTargetTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/7/26.
//

@testable import MirageKitHost
import CoreGraphics
import Testing

#if os(macOS)
@Suite("Desktop Virtual Display Resize Targets", .serialized)
struct DesktopVirtualDisplayResizeTargetTests {
    @Test("Preferred resize targets are cached and replayed")
    func preferredResizeTargetsAreCachedAndReplayed() {
        let request = desktopVirtualDisplayResizeRequest(
            pixelResolution: CGSize(width: 3200, height: 2400),
            refreshRate: 60,
            hiDPI: true,
            colorSpace: .sRGB
        )
        clearDesktopVirtualDisplayResizeTarget(for: request)
        defer { clearDesktopVirtualDisplayResizeTarget(for: request) }

        recordDesktopVirtualDisplayResizeTargetSuccess(
            pixelResolution: CGSize(width: 3200, height: 2400),
            scaleFactor: 2.0,
            refreshRate: 60,
            colorSpace: .sRGB,
            targetTier: .preferred,
            for: request
        )

        let cached = cachedDesktopVirtualDisplayResizeTarget(for: request)

        #expect(cached?.pixelWidth == 3200)
        #expect(cached?.pixelHeight == 2400)
        #expect(cached?.refreshRate == 60)
        #expect(cached?.hiDPI == true)
        #expect(cached?.colorSpace == .sRGB)
    }

    @Test("Degraded resize targets are not persisted")
    func degradedResizeTargetsAreNotPersisted() {
        let request = desktopVirtualDisplayResizeRequest(
            pixelResolution: CGSize(width: 1984, height: 2192),
            refreshRate: 60,
            hiDPI: true,
            colorSpace: .sRGB
        )
        clearDesktopVirtualDisplayResizeTarget(for: request)
        defer { clearDesktopVirtualDisplayResizeTarget(for: request) }

        recordDesktopVirtualDisplayResizeTargetSuccess(
            pixelResolution: CGSize(width: 1984, height: 2192),
            scaleFactor: 1.0,
            refreshRate: 60,
            colorSpace: .sRGB,
            targetTier: .degraded,
            for: request
        )

        #expect(cachedDesktopVirtualDisplayResizeTarget(for: request) == nil)
    }

    @Test("Resize target cache clears failed entries")
    func resizeTargetCacheClearsFailedEntries() {
        let request = desktopVirtualDisplayResizeRequest(
            pixelResolution: CGSize(width: 1984, height: 2192),
            refreshRate: 60,
            hiDPI: true,
            colorSpace: .sRGB
        )
        clearDesktopVirtualDisplayResizeTarget(for: request)
        recordDesktopVirtualDisplayResizeTargetSuccess(
            pixelResolution: CGSize(width: 1984, height: 2192),
            scaleFactor: 2.0,
            refreshRate: 60,
            colorSpace: .sRGB,
            targetTier: .preferred,
            for: request
        )

        clearDesktopVirtualDisplayResizeTarget(for: request)

        #expect(cachedDesktopVirtualDisplayResizeTarget(for: request) == nil)
    }
}
#endif
