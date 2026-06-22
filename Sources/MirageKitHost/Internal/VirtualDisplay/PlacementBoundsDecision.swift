//
//  PlacementBoundsDecision.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//
//  Virtual-display placement bounds selection policy.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
#if os(macOS)
import CoreGraphics

enum PlacementBoundsDecisionOutcome: String, Equatable {
    case adoptRecomputedCachedOutsideDisplay = "adopt_recomputed_cached_outside_display"
    case adoptRecomputedGrowth = "adopt_recomputed_growth"
    case adoptRecomputedShrink = "adopt_recomputed_shrink"
    case useCachedMismatch = "use_cached_mismatch"
}

struct PlacementBoundsDecisionConfig: Equatable {
    var sizeTolerance: CGFloat = 12
    var originTolerance: CGFloat = 32
    var minimumSignificantDelta: CGFloat = 24
    var maximumAcceptedShrinkRatio: CGFloat = 0.35
    var maximumAcceptedAbsoluteShrink: CGFloat = 140
}

struct PlacementBoundsDecision: Equatable {
    let outcome: PlacementBoundsDecisionOutcome
    let resolvedBounds: CGRect
}

func placementBoundsSelectionDecision(
    cachedBounds: CGRect,
    recomputedBounds: CGRect,
    displayBounds: CGRect,
    config: PlacementBoundsDecisionConfig = .init()
)
-> PlacementBoundsDecision {
    let cached = cachedBounds.standardized
    let recomputed = recomputedBounds.standardized
    let display = displayBounds.standardized

    guard cached.width > 0, cached.height > 0 else {
        return PlacementBoundsDecision(outcome: .adoptRecomputedGrowth, resolvedBounds: recomputed)
    }
    guard recomputed.width > 0, recomputed.height > 0 else {
        return PlacementBoundsDecision(outcome: .useCachedMismatch, resolvedBounds: cached)
    }

    let displayContainmentBounds = display.insetBy(dx: -1, dy: -1)
    let displayContainsCached = displayContainmentBounds.contains(cached)
    let displayContainsRecomputed = displayContainmentBounds.contains(recomputed)
    if displayContainsRecomputed, !displayContainsCached {
        return PlacementBoundsDecision(
            outcome: .adoptRecomputedCachedOutsideDisplay,
            resolvedBounds: recomputed
        )
    }

    let originClose = abs(recomputed.minX - cached.minX) <= config.originTolerance &&
        abs(recomputed.minY - cached.minY) <= config.originTolerance
    guard originClose, displayContainsRecomputed else {
        return PlacementBoundsDecision(outcome: .useCachedMismatch, resolvedBounds: cached)
    }

    let widthDelta = recomputed.width - cached.width
    let heightDelta = recomputed.height - cached.height
    let widthDeltaAbsolute = abs(widthDelta)
    let heightDeltaAbsolute = abs(heightDelta)
    let maxAbsoluteDelta = max(widthDeltaAbsolute, heightDeltaAbsolute)
    let minimumDimension = max(1, min(cached.width, cached.height))
    let maxRelativeDelta = maxAbsoluteDelta / minimumDimension
    let isSignificantDelta = maxAbsoluteDelta >= config.minimumSignificantDelta

    enum AxisTrend {
        case growth
        case shrink
        case stable
    }

    func trend(for delta: CGFloat, tolerance: CGFloat) -> AxisTrend {
        if delta > tolerance { return .growth }
        if delta < -tolerance { return .shrink }
        return .stable
    }

    let widthTrend = trend(for: widthDelta, tolerance: config.sizeTolerance)
    let heightTrend = trend(for: heightDelta, tolerance: config.sizeTolerance)
    let hasGrowth = widthTrend == .growth || heightTrend == .growth
    let hasShrink = widthTrend == .shrink || heightTrend == .shrink

    if hasGrowth, hasShrink, isSignificantDelta {
        return PlacementBoundsDecision(outcome: .useCachedMismatch, resolvedBounds: cached)
    }

    let exceedsAbsoluteCap = maxAbsoluteDelta > config.maximumAcceptedAbsoluteShrink
    let exceedsRatioCap = maxRelativeDelta > config.maximumAcceptedShrinkRatio
    if isSignificantDelta, exceedsAbsoluteCap || exceedsRatioCap {
        return PlacementBoundsDecision(outcome: .useCachedMismatch, resolvedBounds: cached)
    }

    if hasShrink {
        return PlacementBoundsDecision(outcome: .adoptRecomputedShrink, resolvedBounds: recomputed)
    }
    if hasGrowth {
        return PlacementBoundsDecision(outcome: .adoptRecomputedGrowth, resolvedBounds: recomputed)
    }

    let cachedArea = cached.width * cached.height
    let recomputedArea = recomputed.width * recomputed.height
    let outcome: PlacementBoundsDecisionOutcome = recomputedArea >= cachedArea
        ? .adoptRecomputedGrowth
        : .adoptRecomputedShrink
    return PlacementBoundsDecision(outcome: outcome, resolvedBounds: recomputed)
}
#endif
