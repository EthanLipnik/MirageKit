//
//  VirtualDisplayFallbackCacheTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/4/26.
//

@testable import MirageKit
@testable import MirageKitHost
import Foundation
import Testing

#if os(macOS)
@Suite("Virtual Display Fallback Cache")
struct VirtualDisplayFallbackCacheTests {
    @Test("Cache pruning keeps entries newer than 45 days")
    func cachePruningKeepsOnlyFreshEntries() {
        let now = Date()
        let freshCondition = SharedVirtualDisplayManager.DisplayFallbackCondition(
            requestedWidth: 2450,
            requestedHeight: 1608,
            refreshRate: 60,
            requestedColorSpace: .displayP3
        )
        let expiredCondition = SharedVirtualDisplayManager.DisplayFallbackCondition(
            requestedWidth: 2880,
            requestedHeight: 1800,
            refreshRate: 60,
            requestedColorSpace: .displayP3
        )

        let freshOutcome = SharedVirtualDisplayManager.DisplayFallbackOutcome(
            resolvedWidth: 2450,
            resolvedHeight: 1608,
            resolvedHiDPI: false,
            resolvedColorSpace: .displayP3,
            rungLabel: "requested-1x-P3",
            observedAt: now.addingTimeInterval(-(44 * 24 * 60 * 60))
        )
        let expiredOutcome = SharedVirtualDisplayManager.DisplayFallbackOutcome(
            resolvedWidth: 2880,
            resolvedHeight: 1800,
            resolvedHiDPI: false,
            resolvedColorSpace: .displayP3,
            rungLabel: "requested-1x-P3",
            observedAt: now.addingTimeInterval(-(46 * 24 * 60 * 60))
        )

        let pruned = SharedVirtualDisplayManager.prunedFallbackOutcomeCache(
            [
                freshCondition: freshOutcome,
                expiredCondition: expiredOutcome,
            ],
            now: now
        )

        #expect(pruned[freshCondition] != nil)
        #expect(pruned[expiredCondition] == nil)
    }

    @Test("Cache persistence round-trip drops non-fallback outcomes")
    func cachePersistenceDropsNonFallbackOutcomes() {
        let suiteName = "VirtualDisplayFallbackCacheTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Failed to create isolated defaults suite \(suiteName)")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let now = Date()
        let fallbackCondition = SharedVirtualDisplayManager.DisplayFallbackCondition(
            requestedWidth: 3024,
            requestedHeight: 1964,
            refreshRate: 60,
            requestedColorSpace: .displayP3
        )
        let nonFallbackCondition = SharedVirtualDisplayManager.DisplayFallbackCondition(
            requestedWidth: 2560,
            requestedHeight: 1600,
            refreshRate: 60,
            requestedColorSpace: .displayP3
        )

        let fallbackOutcome = SharedVirtualDisplayManager.DisplayFallbackOutcome(
            resolvedWidth: 3024,
            resolvedHeight: 1964,
            resolvedHiDPI: false,
            resolvedColorSpace: .displayP3,
            rungLabel: "requested-1x-P3",
            observedAt: now
        )
        let nonFallbackOutcome = SharedVirtualDisplayManager.DisplayFallbackOutcome(
            resolvedWidth: 2560,
            resolvedHeight: 1600,
            resolvedHiDPI: true,
            resolvedColorSpace: .displayP3,
            rungLabel: "requested-retina-P3",
            observedAt: now
        )

        SharedVirtualDisplayManager.persistFallbackOutcomeCache(
            [
                fallbackCondition: fallbackOutcome,
                nonFallbackCondition: nonFallbackOutcome,
            ],
            defaults: defaults,
            now: now
        )

        let loaded = SharedVirtualDisplayManager.loadFallbackOutcomeCache(defaults: defaults, now: now)
        #expect(loaded[fallbackCondition] != nil)
        #expect(loaded[nonFallbackCondition] == nil)
    }

    @Test("Fallback classification matches requested retina path")
    func fallbackClassification() {
        let condition = SharedVirtualDisplayManager.DisplayFallbackCondition(
            requestedWidth: 1920,
            requestedHeight: 1200,
            refreshRate: 60,
            requestedColorSpace: .displayP3
        )
        let requestedPath = SharedVirtualDisplayManager.DisplayFallbackOutcome(
            resolvedWidth: 1920,
            resolvedHeight: 1200,
            resolvedHiDPI: true,
            resolvedColorSpace: .displayP3,
            rungLabel: "requested-retina-P3",
            observedAt: Date()
        )
        let fallbackPath = SharedVirtualDisplayManager.DisplayFallbackOutcome(
            resolvedWidth: 1920,
            resolvedHeight: 1200,
            resolvedHiDPI: false,
            resolvedColorSpace: .displayP3,
            rungLabel: "requested-1x-P3",
            observedAt: Date()
        )

        #expect(!SharedVirtualDisplayManager.isFallbackOutcome(condition: condition, outcome: requestedPath))
        #expect(SharedVirtualDisplayManager.isFallbackOutcome(condition: condition, outcome: fallbackPath))
    }
}
#endif
