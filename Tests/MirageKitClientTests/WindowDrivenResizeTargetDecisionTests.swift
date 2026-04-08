//
//  WindowDrivenResizeTargetDecisionTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/7/26.
//
//  Window-driven resize target policy.
//

@testable import MirageKitClient
import CoreGraphics
import Testing

@Suite("Window Driven Resize Target Decision")
struct WindowDrivenResizeTargetDecisionTests {
    @Test("Desktop resize target prefers platform container over fitted drawable size")
    func desktopResizePrefersContainerSize() {
        let decision = windowDrivenResizeTargetDecision(
            containerSize: CGSize(width: 1440, height: 900),
            fallbackDrawableSize: CGSize(width: 1200, height: 675),
            suppressForLocalPresentation: false
        )

        #expect(decision == .useContainerSize(CGSize(width: 1440, height: 900)))
    }

    @Test("App resize target prefers platform container over fitted drawable size")
    func appResizePrefersContainerSize() {
        let decision = windowDrivenResizeTargetDecision(
            containerSize: CGSize(width: 1180, height: 820),
            fallbackDrawableSize: CGSize(width: 1000, height: 700),
            suppressForLocalPresentation: false
        )

        #expect(decision == .useContainerSize(CGSize(width: 1180, height: 820)))
    }

    @Test("Drawable size is only a fallback when platform container size is unavailable")
    func fallbackUsesDrawableSizeOnlyWhenNeeded() {
        let decision = windowDrivenResizeTargetDecision(
            containerSize: .zero,
            fallbackDrawableSize: CGSize(width: 1366, height: 768),
            suppressForLocalPresentation: false
        )

        #expect(decision == .useContainerSize(CGSize(width: 1366, height: 768)))
    }

    @Test("Local presentation suppression keeps resize client-side")
    func localPresentationSuppressesHostResize() {
        let decision = windowDrivenResizeTargetDecision(
            containerSize: CGSize(width: 1024, height: 748),
            fallbackDrawableSize: CGSize(width: 800, height: 600),
            suppressForLocalPresentation: true
        )

        #expect(decision == .suppressForLocalPresentation)
    }
}
