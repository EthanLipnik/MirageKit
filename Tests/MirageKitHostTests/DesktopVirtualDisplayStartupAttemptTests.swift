//
//  DesktopVirtualDisplayStartupAttemptTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/10/26.
//

@testable import MirageKitHost
import CoreGraphics
import Testing

#if os(macOS)
@Suite("Desktop Virtual Display Startup Attempts", .serialized)
struct DesktopVirtualDisplayStartupAttemptTests {
    @Test("Startup attempts add one conservative retry for high-end requests")
    func startupAttemptsAddConservativeRetryForHighEndRequests() {
        let plan = desktopVirtualDisplayStartupPlan(
            logicalResolution: CGSize(width: 3008, height: 1692),
            requestedScaleFactor: 2.0,
            requestedRefreshRate: 120,
            requestedColorDepth: .pro,
            requestedColorSpace: .displayP3
        )
        clearDesktopVirtualDisplayStartupTarget(for: plan.request)
        defer { clearDesktopVirtualDisplayStartupTarget(for: plan.request) }

        let attempts = desktopVirtualDisplayStartupPlan(
            logicalResolution: CGSize(width: 3008, height: 1692),
            requestedScaleFactor: 2.0,
            requestedRefreshRate: 120,
            requestedColorDepth: .pro,
            requestedColorSpace: .displayP3
        ).attempts

        #expect(attempts.count == 3)
        #expect(attempts[0].label == "primary")
        #expect(attempts[0].backingScale.pixelResolution == CGSize(width: 6016, height: 3376))
        #expect(attempts[0].refreshRate == 120)
        #expect(attempts[0].colorSpace == .displayP3)
        #expect(attempts[0].fallbackKind == .primary)
        #expect(!attempts[0].isConservativeRetry)
        #expect(!attempts[0].isCachedTarget)

        #expect(attempts[1].label == "descriptor-fallback-sRGB")
        #expect(attempts[1].backingScale.pixelResolution == CGSize(width: 6016, height: 3376))
        #expect(attempts[1].refreshRate == 120)
        #expect(attempts[1].colorSpace == .sRGB)
        #expect(attempts[1].fallbackKind == .descriptorFallback)
        #expect(!attempts[1].isConservativeRetry)

        #expect(attempts[2].label == "conservative-retry")
        #expect(attempts[2].backingScale.pixelResolution == CGSize(width: 3008, height: 1680))
        #expect(attempts[2].refreshRate == 120)
        #expect(attempts[2].colorSpace == .sRGB)
        #expect(attempts[2].fallbackKind == .conservative)
        #expect(attempts[2].isConservativeRetry)
        #expect(!attempts[2].isCachedTarget)
    }

    @Test("Startup attempts avoid duplicate conservative retry when request is already safe")
    func startupAttemptsAvoidDuplicateConservativeRetryWhenRequestIsAlreadySafe() {
        let plan = desktopVirtualDisplayStartupPlan(
            logicalResolution: CGSize(width: 1920, height: 1080),
            requestedScaleFactor: 1.0,
            requestedRefreshRate: 60,
            requestedColorDepth: .standard,
            requestedColorSpace: .sRGB
        )
        clearDesktopVirtualDisplayStartupTarget(for: plan.request)
        defer { clearDesktopVirtualDisplayStartupTarget(for: plan.request) }

        let attempts = desktopVirtualDisplayStartupPlan(
            logicalResolution: CGSize(width: 1920, height: 1080),
            requestedScaleFactor: 1.0,
            requestedRefreshRate: 60,
            requestedColorDepth: .standard,
            requestedColorSpace: .sRGB
        ).attempts

        #expect(attempts.count == 1)
        #expect(attempts[0].label == "primary")
        #expect(attempts[0].backingScale.pixelResolution == CGSize(width: 1920, height: 1072))
        #expect(attempts[0].refreshRate == 60)
        #expect(attempts[0].colorSpace == .sRGB)
        #expect(!attempts[0].isCachedTarget)
    }

    @Test("Startup attempts prefer Retina equivalent for large 1x requests")
    func startupAttemptsPreferRetinaEquivalentForLargeOneXRequests() {
        let plan = desktopVirtualDisplayStartupPlan(
            logicalResolution: CGSize(width: 2304, height: 1296),
            requestedScaleFactor: 1.0,
            requestedRefreshRate: 60,
            requestedColorDepth: .standard,
            requestedColorSpace: .sRGB
        )
        clearDesktopVirtualDisplayStartupTarget(for: plan.request)
        defer { clearDesktopVirtualDisplayStartupTarget(for: plan.request) }

        let attempts = desktopVirtualDisplayStartupPlan(
            logicalResolution: CGSize(width: 2304, height: 1296),
            requestedScaleFactor: 1.0,
            requestedRefreshRate: 60,
            requestedColorDepth: .standard,
            requestedColorSpace: .sRGB
        ).attempts

        #expect(attempts.count == 2)
        #expect(attempts[0].label == "retina-equivalent")
        #expect(attempts[0].backingScale.scaleFactor == 2.0)
        #expect(attempts[0].backingScale.pixelResolution == CGSize(width: 2304, height: 1296))
        #expect(attempts[1].label == "primary")
        #expect(attempts[1].backingScale.scaleFactor == 1.0)
        #expect(attempts[1].backingScale.pixelResolution == CGSize(width: 2304, height: 1296))
    }

    @Test("Degraded startup targets are not persisted as preferred cache entries")
    func degradedStartupTargetsAreNotPersistedAsPreferredCacheEntries() {
        let initialPlan = desktopVirtualDisplayStartupPlan(
            logicalResolution: CGSize(width: 3008, height: 1692),
            requestedScaleFactor: 2.0,
            requestedRefreshRate: 120,
            requestedColorDepth: .pro,
            requestedColorSpace: .displayP3
        )
        clearDesktopVirtualDisplayStartupTarget(for: initialPlan.request)
        defer { clearDesktopVirtualDisplayStartupTarget(for: initialPlan.request) }

        recordDesktopVirtualDisplayStartupTargetSuccess(
            pixelResolution: CGSize(width: 3008, height: 1680),
            scaleFactor: 1.0,
            refreshRate: 60,
            colorSpace: .sRGB,
            targetTier: .degraded,
            for: initialPlan.request
        )

        let attempts = desktopVirtualDisplayStartupPlan(
            logicalResolution: CGSize(width: 3008, height: 1692),
            requestedScaleFactor: 2.0,
            requestedRefreshRate: 120,
            requestedColorDepth: .pro,
            requestedColorSpace: .displayP3
        ).attempts

        #expect(attempts.count == 3)
        #expect(attempts[0].label == "primary")
        #expect(!attempts[0].isCachedTarget)
        #expect(attempts[1].label == "descriptor-fallback-sRGB")
        #expect(attempts[2].label == "conservative-retry")
    }

    @Test("Cached target identical to primary does not duplicate the ladder")
    func cachedTargetIdenticalToPrimaryIsDeduplicated() {
        let initialPlan = desktopVirtualDisplayStartupPlan(
            logicalResolution: CGSize(width: 3008, height: 1692),
            requestedScaleFactor: 2.0,
            requestedRefreshRate: 120,
            requestedColorDepth: .pro,
            requestedColorSpace: .displayP3
        )
        clearDesktopVirtualDisplayStartupTarget(for: initialPlan.request)
        defer { clearDesktopVirtualDisplayStartupTarget(for: initialPlan.request) }

        recordDesktopVirtualDisplayStartupTargetSuccess(
            pixelResolution: CGSize(width: 6016, height: 3376),
            scaleFactor: 2.0,
            refreshRate: 120,
            colorSpace: .displayP3,
            targetTier: .preferred,
            for: initialPlan.request
        )

        let attempts = desktopVirtualDisplayStartupPlan(
            logicalResolution: CGSize(width: 3008, height: 1692),
            requestedScaleFactor: 2.0,
            requestedRefreshRate: 120,
            requestedColorDepth: .pro,
            requestedColorSpace: .displayP3
        ).attempts

        #expect(attempts.count == 3)
        #expect(attempts[0].isCachedTarget)
        #expect(attempts[1].label == "descriptor-fallback-sRGB")
        #expect(attempts[2].label == "conservative-retry")
    }
}
#endif
