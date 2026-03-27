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

        let attempts = desktopVirtualDisplayStartupAttempts(
            logicalResolution: CGSize(width: 3008, height: 1692),
            requestedScaleFactor: 2.0,
            requestedRefreshRate: 120,
            requestedColorDepth: .pro,
            requestedColorSpace: .displayP3
        )

        #expect(attempts.count == 2)
        #expect(attempts[0].label == "primary")
        #expect(attempts[0].backingScale.pixelResolution == CGSize(width: 6016, height: 3376))
        #expect(attempts[0].refreshRate == 120)
        #expect(attempts[0].colorSpace == .displayP3)
        #expect(!attempts[0].isConservativeRetry)
        #expect(!attempts[0].isCachedTarget)

        #expect(attempts[1].label == "conservative-retry")
        #expect(attempts[1].backingScale.pixelResolution == CGSize(width: 3008, height: 1680))
        #expect(attempts[1].refreshRate == 60)
        #expect(attempts[1].colorSpace == .sRGB)
        #expect(attempts[1].isConservativeRetry)
        #expect(!attempts[1].isCachedTarget)
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

        let attempts = desktopVirtualDisplayStartupAttempts(
            logicalResolution: CGSize(width: 1920, height: 1080),
            requestedScaleFactor: 1.0,
            requestedRefreshRate: 60,
            requestedColorDepth: .standard,
            requestedColorSpace: .sRGB
        )

        #expect(attempts.count == 1)
        #expect(attempts[0].label == "primary")
        #expect(attempts[0].backingScale.pixelResolution == CGSize(width: 1920, height: 1072))
        #expect(attempts[0].refreshRate == 60)
        #expect(attempts[0].colorSpace == .sRGB)
        #expect(!attempts[0].isCachedTarget)
    }

    @Test("Cached winning target is tried before the default ladder")
    func cachedWinningTargetIsTriedFirst() {
        let initialPlan = desktopVirtualDisplayStartupPlan(
            logicalResolution: CGSize(width: 3008, height: 1692),
            requestedScaleFactor: 2.0,
            requestedRefreshRate: 120,
            requestedColorDepth: .pro,
            requestedColorSpace: .displayP3
        )
        clearDesktopVirtualDisplayStartupTarget(for: initialPlan.request)
        defer { clearDesktopVirtualDisplayStartupTarget(for: initialPlan.request) }

        let cachedAttempt = DesktopVirtualDisplayStartupAttempt(
            backingScale: DesktopBackingScaleResolution(
                scaleFactor: 1.0,
                pixelResolution: CGSize(width: 3008, height: 1680)
            ),
            refreshRate: 60,
            colorSpace: .sRGB,
            label: "conservative-retry",
            isConservativeRetry: true,
            isCachedTarget: false
        )
        recordDesktopVirtualDisplayStartupTargetSuccess(cachedAttempt, for: initialPlan.request)

        let attempts = desktopVirtualDisplayStartupAttempts(
            logicalResolution: CGSize(width: 3008, height: 1692),
            requestedScaleFactor: 2.0,
            requestedRefreshRate: 120,
            requestedColorDepth: .pro,
            requestedColorSpace: .displayP3
        )

        #expect(attempts.count == 2)
        #expect(attempts[0].isCachedTarget)
        #expect(attempts[0].backingScale.pixelResolution == CGSize(width: 3008, height: 1680))
        #expect(attempts[0].refreshRate == 60)
        #expect(attempts[0].colorSpace == .sRGB)
        #expect(attempts[1].label == "primary")
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
            DesktopVirtualDisplayStartupAttempt(
                backingScale: DesktopBackingScaleResolution(
                    scaleFactor: 2.0,
                    pixelResolution: CGSize(width: 6016, height: 3376)
                ),
                refreshRate: 120,
                colorSpace: .displayP3,
                label: "primary",
                isConservativeRetry: false,
                isCachedTarget: false
            ),
            for: initialPlan.request
        )

        let attempts = desktopVirtualDisplayStartupAttempts(
            logicalResolution: CGSize(width: 3008, height: 1692),
            requestedScaleFactor: 2.0,
            requestedRefreshRate: 120,
            requestedColorDepth: .pro,
            requestedColorSpace: .displayP3
        )

        #expect(attempts.count == 2)
        #expect(attempts[0].isCachedTarget)
        #expect(attempts[1].label == "conservative-retry")
    }
}
#endif
