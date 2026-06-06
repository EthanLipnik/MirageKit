//
//  VirtualDisplaySourcePixelBudgetTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/18/26.
//

@testable import MirageKitHost
import CoreGraphics
import Foundation
import MirageKit
import Testing

#if os(macOS)
@Suite("Virtual Display Source Pixel Budget")
struct VirtualDisplaySourcePixelBudgetTests {
    @Test("Resource budget keeps Retina attempt when current topology has headroom")
    func resourceBudgetKeepsRetinaAttemptWithHeadroom() {
        let budget = VirtualDisplaySourcePixelBudget(
            totalSourcePixels: 30_965_760,
            safetyMarginPixels: 1_000_000,
            displayLoads: [
                .init(displayID: 1, sourcePixels: 14_745_600),
            ]
        )
        let attempt = SharedVirtualDisplayManager.DisplayCreationAttempt(
            resolution: CGSize(width: 3200, height: 2400),
            hiDPI: true,
            colorSpace: .displayP3,
            label: "explicit-retina"
        )

        let resolved = SharedVirtualDisplayManager.resourceBudgetedCreationAttempt(attempt, budget: budget)

        #expect(resolved == attempt)
    }

    @Test("Resource budget caps Retina attempt before exhausting display controller source pixels")
    func resourceBudgetCapsRetinaAttemptBeforeExhaustingSourcePixels() {
        let budget = VirtualDisplaySourcePixelBudget(
            totalSourcePixels: 30_965_760,
            safetyMarginPixels: 1_000_000,
            displayLoads: [
                .init(displayID: 1, sourcePixels: 18_662_400),
                .init(displayID: 2, sourcePixels: 5_760_000),
            ]
        )
        let attempt = SharedVirtualDisplayManager.DisplayCreationAttempt(
            resolution: CGSize(width: 3200, height: 2400),
            hiDPI: true,
            colorSpace: .displayP3,
            label: "explicit-retina"
        )

        let resolved = SharedVirtualDisplayManager.resourceBudgetedCreationAttempt(attempt, budget: budget)

        #expect(resolved.hiDPI)
        #expect(resolved.colorSpace == .displayP3)
        #expect(resolved.label == "resource-budgeted-retina-explicit-retina")
        #expect(resolved.resolution.width < attempt.resolution.width)
        #expect(resolved.resolution.height < attempt.resolution.height)
        #expect(
            VirtualDisplaySourcePixelBudget.pixelArea(resolved.resolution) <= budget.availableSourcePixels
        )
    }

    @Test("Resource budget preemptively adjusts Retina attempt")
    func resourceBudgetPreemptivelyAdjustsRetinaAttempt() {
        let budget = VirtualDisplaySourcePixelBudget(
            totalSourcePixels: 30_965_760,
            safetyMarginPixels: 1_000_000,
            displayLoads: [
                .init(displayID: 1, sourcePixels: 18_662_400),
            ]
        )

        let attempts = SharedVirtualDisplayManager.shared.creationAttempts(
            resolution: CGSize(width: 6000, height: 3376),
            colorSpace: .sRGB,
            policy: .singleAttempt(hiDPI: true),
            sourcePixelBudget: budget
        )

        #expect(attempts.count == 1)
        #expect(attempts[0].resolution.width < 6000)
        #expect(attempts[0].resolution.height < 3376)
        #expect(attempts[0].hiDPI)
        #expect(attempts[0].label == "resource-budgeted-retina-explicit-retina")
    }

    @Test("Resource budget is scoped to macOS 27")
    func resourceBudgetIsScopedToMacOS27() {
        #expect(
            VirtualDisplaySourcePixelBudget.isRequiredForVirtualDisplayStartup(
                osVersion: OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)
            )
        )
        #expect(
            !VirtualDisplaySourcePixelBudget.isRequiredForVirtualDisplayStartup(
                osVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 6, patchVersion: 0)
            )
        )
        #expect(
            !VirtualDisplaySourcePixelBudget.isRequiredForVirtualDisplayStartup(
                osVersion: OperatingSystemVersion(majorVersion: 28, minorVersion: 0, patchVersion: 0)
            )
        )
    }

    @Test("Resource budget falls back to 1x when no useful Retina size fits")
    func resourceBudgetFallsBackToOneXWhenRetinaCannotFit() {
        let budget = VirtualDisplaySourcePixelBudget(
            totalSourcePixels: 30_965_760,
            safetyMarginPixels: 1_000_000,
            displayLoads: [
                .init(displayID: 1, sourcePixels: 29_500_000),
            ]
        )
        let attempt = SharedVirtualDisplayManager.DisplayCreationAttempt(
            resolution: CGSize(width: 3200, height: 2400),
            hiDPI: true,
            colorSpace: .sRGB,
            label: "explicit-retina"
        )

        let resolved = SharedVirtualDisplayManager.resourceBudgetedCreationAttempt(attempt, budget: budget)

        #expect(!resolved.hiDPI)
        #expect(resolved.colorSpace == .sRGB)
        #expect(resolved.label == "resource-budgeted-1x-explicit-retina")
        #expect(resolved.resolution == CGSize(width: 1600, height: 1200))
    }
}
#endif
