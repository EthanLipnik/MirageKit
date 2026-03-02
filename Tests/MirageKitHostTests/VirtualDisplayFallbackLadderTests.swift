//
//  VirtualDisplayFallbackLadderTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/1/26.
//
//  Coverage for virtual display fallback ladder ordering and aspect safety.
//

@testable import MirageKitHost
import CoreGraphics
import Testing

#if os(macOS)
@Suite("Virtual Display Fallback Ladder")
struct VirtualDisplayFallbackLadderTests {
    @Test("Fallback ladder prefers requested Retina then requested 1x")
    func fallbackLadderStartsWithRequestedRetinaAndOneX() {
        let requested = CGSize(width: 2450, height: 1608)
        let plan = SharedVirtualDisplayManager.fallbackAttemptPlan(for: requested)

        #expect(plan.count >= 2)
        #expect(plan[0].rung == "requested-retina")
        #expect(plan[0].hiDPI)
        #expect(plan[0].resolution == CGSize(width: 2450, height: 1608))

        #expect(plan[1].rung == "requested-1x")
        #expect(!plan[1].hiDPI)
        #expect(plan[1].resolution == SharedVirtualDisplayManager.fallbackResolution(for: requested))
    }

    @Test("Closest-aspect candidates are ordered by descending area")
    func closestAspectCandidatesUseLargestAreaFirst() {
        let requested = CGSize(width: 2450, height: 1608)
        let plan = SharedVirtualDisplayManager.fallbackAttemptPlan(for: requested)
        let closestRetina = plan.filter { $0.rung == "closest-retina" }
        let closestOneX = plan.filter { $0.rung == "closest-1x" }

        #expect(!closestRetina.isEmpty)
        #expect(!closestOneX.isEmpty)
        let lastClosestRetinaIndex = plan.lastIndex { $0.rung == "closest-retina" }
        let firstClosestOneXIndex = plan.firstIndex { $0.rung == "closest-1x" }
        #expect(lastClosestRetinaIndex != nil)
        #expect(firstClosestOneXIndex != nil)
        if let lastClosestRetinaIndex, let firstClosestOneXIndex {
            #expect(lastClosestRetinaIndex < firstClosestOneXIndex)
        }

        var previousRetinaArea = CGFloat.greatestFiniteMagnitude
        for candidate in closestRetina {
            let area = candidate.resolution.width * candidate.resolution.height
            #expect(area <= previousRetinaArea)
            previousRetinaArea = area
        }

        var previousOneXArea = CGFloat.greatestFiniteMagnitude
        for candidate in closestOneX {
            let area = candidate.resolution.width * candidate.resolution.height
            #expect(area <= previousOneXArea)
            previousOneXArea = area
        }
    }

    @Test("Closest-aspect candidates preserve requested aspect ratio")
    func closestAspectCandidatesPreserveAspectRatio() {
        let requested = CGSize(width: 2450, height: 1608)
        let candidates = SharedVirtualDisplayManager.closestAspectResolutionCandidates(for: requested)

        #expect(!candidates.isEmpty)
        for candidate in candidates {
            let delta = SharedVirtualDisplayManager.aspectRelativeDelta(
                requested: requested,
                candidate: candidate
            )
            #expect(delta <= 0.01)
        }
    }
}
#endif
