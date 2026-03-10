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
@Suite("Desktop Virtual Display Startup Attempts")
struct DesktopVirtualDisplayStartupAttemptTests {
    @Test("Startup attempts add one conservative retry for high-end requests")
    func startupAttemptsAddConservativeRetryForHighEndRequests() {
        let attempts = desktopVirtualDisplayStartupAttempts(
            logicalResolution: CGSize(width: 3008, height: 1692),
            requestedScaleFactor: 2.0,
            streamScale: 1.0,
            disableResolutionCap: true,
            requestedRefreshRate: 120,
            requestedColorSpace: .displayP3
        )

        #expect(attempts.count == 2)
        #expect(attempts[0].label == "primary")
        #expect(attempts[0].backingScale.pixelResolution == CGSize(width: 6016, height: 3384))
        #expect(attempts[0].refreshRate == 120)
        #expect(attempts[0].colorSpace == .displayP3)
        #expect(!attempts[0].isConservativeRetry)

        #expect(attempts[1].label == "conservative-retry")
        #expect(attempts[1].backingScale.pixelResolution == CGSize(width: 3008, height: 1692))
        #expect(attempts[1].refreshRate == 60)
        #expect(attempts[1].colorSpace == .sRGB)
        #expect(attempts[1].isConservativeRetry)
    }

    @Test("Startup attempts avoid duplicate conservative retry when request is already safe")
    func startupAttemptsAvoidDuplicateConservativeRetryWhenRequestIsAlreadySafe() {
        let attempts = desktopVirtualDisplayStartupAttempts(
            logicalResolution: CGSize(width: 1920, height: 1080),
            requestedScaleFactor: 1.0,
            streamScale: 1.0,
            disableResolutionCap: false,
            requestedRefreshRate: 60,
            requestedColorSpace: .sRGB
        )

        #expect(attempts.count == 1)
        #expect(attempts[0].label == "primary")
        #expect(attempts[0].backingScale.pixelResolution == CGSize(width: 1920, height: 1080))
        #expect(attempts[0].refreshRate == 60)
        #expect(attempts[0].colorSpace == .sRGB)
    }
}
#endif
