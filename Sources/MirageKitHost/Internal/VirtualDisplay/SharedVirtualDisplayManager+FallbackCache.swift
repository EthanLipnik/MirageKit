//
//  SharedVirtualDisplayManager+FallbackCache.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/4/26.
//

import MirageKit
#if os(macOS)
import CoreGraphics
import Foundation

extension SharedVirtualDisplayManager {
    // MARK: - Fallback Cache Types

    struct DisplayFallbackCondition: Hashable, Sendable, Codable, Equatable {
        let requestedWidth: Int
        let requestedHeight: Int
        let refreshRate: Int
        let requestedColorSpace: MirageColorSpace
    }

    struct DisplayFallbackOutcome: Sendable, Codable, Equatable {
        let resolvedWidth: Int
        let resolvedHeight: Int
        let resolvedHiDPI: Bool
        let resolvedColorSpace: MirageColorSpace
        let rungLabel: String
        let observedAt: Date
    }

    private struct DisplayFallbackOutcomeRecord: Sendable, Codable {
        let condition: DisplayFallbackCondition
        let outcome: DisplayFallbackOutcome
    }

    private struct DisplayFallbackOutcomeStore: Sendable, Codable {
        let records: [DisplayFallbackOutcomeRecord]
    }

    // MARK: - Fallback Cache Constants

    static let fallbackOutcomeCacheTTL: TimeInterval = 45 * 24 * 60 * 60
    static let fallbackOutcomeCacheDefaultsKey = "Mirage.VirtualDisplay.FallbackOutcomeCache.v1"
    static let fallbackOutcomeCacheLimit = 256

    // MARK: - Fallback Cache Persistence

    static func fallbackCondition(
        for normalizedResolution: CGSize,
        refreshRate: Int,
        requestedColorSpace: MirageColorSpace
    ) -> DisplayFallbackCondition {
        let normalizedWidth = StreamContext.alignedEvenPixel(max(2.0, normalizedResolution.width))
        let normalizedHeight = StreamContext.alignedEvenPixel(max(2.0, normalizedResolution.height))
        return DisplayFallbackCondition(
            requestedWidth: normalizedWidth,
            requestedHeight: normalizedHeight,
            refreshRate: max(1, refreshRate),
            requestedColorSpace: requestedColorSpace
        )
    }

    static func isFallbackOutcome(
        condition: DisplayFallbackCondition,
        outcome: DisplayFallbackOutcome
    ) -> Bool {
        !outcome.resolvedHiDPI ||
            outcome.resolvedColorSpace != condition.requestedColorSpace ||
            outcome.resolvedWidth != condition.requestedWidth ||
            outcome.resolvedHeight != condition.requestedHeight
    }

    static func prunedFallbackOutcomeCache(
        _ cache: [DisplayFallbackCondition: DisplayFallbackOutcome],
        now: Date = Date()
    ) -> [DisplayFallbackCondition: DisplayFallbackOutcome] {
        let cutoff = now.addingTimeInterval(-fallbackOutcomeCacheTTL)
        var pruned: [DisplayFallbackCondition: DisplayFallbackOutcome] = [:]

        for (condition, outcome) in cache {
            guard outcome.observedAt >= cutoff else { continue }
            guard outcome.resolvedWidth > 0, outcome.resolvedHeight > 0 else { continue }
            guard isFallbackOutcome(condition: condition, outcome: outcome) else { continue }
            pruned[condition] = outcome
        }

        if pruned.count > fallbackOutcomeCacheLimit {
            let sorted = pruned
                .sorted { $0.value.observedAt > $1.value.observedAt }
                .prefix(fallbackOutcomeCacheLimit)
            return Dictionary(uniqueKeysWithValues: sorted.map { ($0.key, $0.value) })
        }

        return pruned
    }

    static func loadFallbackOutcomeCache(
        defaults: UserDefaults = .standard,
        now: Date = Date()
    ) -> [DisplayFallbackCondition: DisplayFallbackOutcome] {
        guard let data = defaults.data(forKey: fallbackOutcomeCacheDefaultsKey),
              let store = try? JSONDecoder().decode(DisplayFallbackOutcomeStore.self, from: data) else {
            return [:]
        }

        var loaded: [DisplayFallbackCondition: DisplayFallbackOutcome] = [:]
        for record in store.records {
            if let existing = loaded[record.condition], existing.observedAt >= record.outcome.observedAt {
                continue
            }
            loaded[record.condition] = record.outcome
        }

        return prunedFallbackOutcomeCache(loaded, now: now)
    }

    static func persistFallbackOutcomeCache(
        _ cache: [DisplayFallbackCondition: DisplayFallbackOutcome],
        defaults: UserDefaults = .standard,
        now: Date = Date()
    ) {
        let pruned = prunedFallbackOutcomeCache(cache, now: now)
        guard !pruned.isEmpty else {
            defaults.removeObject(forKey: fallbackOutcomeCacheDefaultsKey)
            return
        }

        let sorted = pruned.sorted { $0.value.observedAt > $1.value.observedAt }
        let records = sorted.map { condition, outcome in
            DisplayFallbackOutcomeRecord(condition: condition, outcome: outcome)
        }
        let store = DisplayFallbackOutcomeStore(records: records)
        guard let data = try? JSONEncoder().encode(store) else { return }
        defaults.set(data, forKey: fallbackOutcomeCacheDefaultsKey)
    }

    // MARK: - Fallback Cache Access

    func cachedFallbackAttempt(
        requestedResolution: CGSize,
        refreshRate: Int,
        requestedColorSpace: MirageColorSpace
    ) -> DisplayCreationAttempt? {
        var cacheChanged = pruneFallbackOutcomeCache()
        let condition = Self.fallbackCondition(
            for: requestedResolution,
            refreshRate: refreshRate,
            requestedColorSpace: requestedColorSpace
        )
        guard let cachedOutcome = fallbackOutcomeByCondition[condition] else {
            if cacheChanged { Self.persistFallbackOutcomeCache(fallbackOutcomeByCondition) }
            return nil
        }

        if !Self.isFallbackOutcome(condition: condition, outcome: cachedOutcome) {
            fallbackOutcomeByCondition.removeValue(forKey: condition)
            cacheChanged = true
            if cacheChanged { Self.persistFallbackOutcomeCache(fallbackOutcomeByCondition) }
            return nil
        }

        if cacheChanged { Self.persistFallbackOutcomeCache(fallbackOutcomeByCondition) }
        let ageDays = Int(Date().timeIntervalSince(cachedOutcome.observedAt) / (24 * 60 * 60))
        MirageLogger.host(
            "Virtual display fallback cache hit (\(ageDays)d): requested=\(condition.requestedWidth)x\(condition.requestedHeight)@\(condition.refreshRate)Hz \(condition.requestedColorSpace.displayName) → resolved=\(cachedOutcome.resolvedWidth)x\(cachedOutcome.resolvedHeight) \(cachedOutcome.resolvedHiDPI ? "retina" : "1x") \(cachedOutcome.resolvedColorSpace.displayName)"
        )
        return DisplayCreationAttempt(
            resolution: CGSize(width: CGFloat(cachedOutcome.resolvedWidth), height: CGFloat(cachedOutcome.resolvedHeight)),
            hiDPI: cachedOutcome.resolvedHiDPI,
            colorSpace: cachedOutcome.resolvedColorSpace,
            label: "cached-fallback-\(cachedOutcome.rungLabel)"
        )
    }

    func cacheFallbackOutcome(
        requestedResolution: CGSize,
        refreshRate: Int,
        requestedColorSpace: MirageColorSpace,
        resolvedResolution: CGSize,
        resolvedScaleFactor: CGFloat,
        resolvedColorSpace: MirageColorSpace,
        rungLabel: String
    ) {
        let condition = Self.fallbackCondition(
            for: requestedResolution,
            refreshRate: refreshRate,
            requestedColorSpace: requestedColorSpace
        )
        let outcome = DisplayFallbackOutcome(
            resolvedWidth: StreamContext.alignedEvenPixel(max(2.0, resolvedResolution.width)),
            resolvedHeight: StreamContext.alignedEvenPixel(max(2.0, resolvedResolution.height)),
            resolvedHiDPI: resolvedScaleFactor > 1.5,
            resolvedColorSpace: resolvedColorSpace,
            rungLabel: rungLabel,
            observedAt: Date()
        )

        guard Self.isFallbackOutcome(condition: condition, outcome: outcome) else {
            clearCachedFallbackOutcome(
                requestedResolution: requestedResolution,
                refreshRate: refreshRate,
                requestedColorSpace: requestedColorSpace
            )
            return
        }

        fallbackOutcomeByCondition[condition] = outcome
        pruneFallbackOutcomeCache()
        Self.persistFallbackOutcomeCache(fallbackOutcomeByCondition)
        MirageLogger.host(
            "Virtual display fallback cache stored: requested=\(condition.requestedWidth)x\(condition.requestedHeight)@\(condition.refreshRate)Hz \(condition.requestedColorSpace.displayName) → resolved=\(outcome.resolvedWidth)x\(outcome.resolvedHeight) \(outcome.resolvedHiDPI ? "retina" : "1x") \(outcome.resolvedColorSpace.displayName)"
        )
    }

    func clearCachedFallbackOutcome(
        requestedResolution: CGSize,
        refreshRate: Int,
        requestedColorSpace: MirageColorSpace
    ) {
        let condition = Self.fallbackCondition(
            for: requestedResolution,
            refreshRate: refreshRate,
            requestedColorSpace: requestedColorSpace
        )
        guard fallbackOutcomeByCondition.removeValue(forKey: condition) != nil else { return }
        Self.persistFallbackOutcomeCache(fallbackOutcomeByCondition)
    }

    @discardableResult
    private func pruneFallbackOutcomeCache(now: Date = Date()) -> Bool {
        let pruned = Self.prunedFallbackOutcomeCache(fallbackOutcomeByCondition, now: now)
        guard pruned != fallbackOutcomeByCondition else { return false }
        fallbackOutcomeByCondition = pruned
        return true
    }
}
#endif
