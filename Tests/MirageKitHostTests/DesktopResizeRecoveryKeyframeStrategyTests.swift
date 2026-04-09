//
//  DesktopResizeRecoveryKeyframeStrategyTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/8/26.
//
//  Desktop resize recovery-keyframe staging policy tests.
//

@testable import MirageKitHost
import Testing

#if os(macOS)
@Suite("Desktop Resize Recovery Keyframe Strategy")
struct DesktopResizeRecoveryKeyframeStrategyTests {
    @Test("Desktop resize reset defers keyframe staging while encoding is suspended")
    func desktopResizeResetDefersKeyframeWhileEncodingSuspended() {
        let decision = desktopResizeRecoveryKeyframeStrategy(
            encodingSuspendedForResize: true
        )

        #expect(decision == .deferUntilResume)
    }

    @Test("Desktop resize reset can stage keyframe immediately once encoding is live")
    func desktopResizeResetCanStageKeyframeWhenEncodingIsLive() {
        let decision = desktopResizeRecoveryKeyframeStrategy(
            encodingSuspendedForResize: false
        )

        #expect(decision == .scheduleDuringReset)
    }
}
#endif
