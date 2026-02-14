//
//  RenderRecoveryPolicyTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/13/26.
//
//  Coverage for iOS render recovery state machine transitions.
//

@testable import MirageKitClient
import Testing

#if os(macOS)
@Suite("Render Recovery Policy")
struct RenderRecoveryPolicyTests {
    @Test("Auto low FPS alone does not enter recovery without pressure")
    func autoLowFPSWithoutPressureDoesNotEnterRecovery() {
        var policy = MirageRenderStabilityPolicy()

        let first = policy.evaluate(
            now: 100,
            latencyMode: .auto,
            targetFPS: 60,
            renderedFPS: 40,
            drawableWaitAvgMs: 10,
            hasCapPressure: false
        )
        let second = policy.evaluate(
            now: 102,
            latencyMode: .auto,
            targetFPS: 60,
            renderedFPS: 40,
            drawableWaitAvgMs: 10,
            hasCapPressure: false
        )
        #expect(!first.recoveryEntered)
        #expect(!second.recoveryEntered)
        #expect(!policy.snapshot().recoveryActive)
    }

    @Test("Auto low FPS with cap pressure enters recovery")
    func autoLowFPSWithCapPressureEntersRecovery() {
        var policy = MirageRenderStabilityPolicy()

        _ = policy.evaluate(
            now: 100,
            latencyMode: .auto,
            targetFPS: 60,
            renderedFPS: 40,
            drawableWaitAvgMs: 10,
            hasCapPressure: true
        )
        let second = policy.evaluate(
            now: 102,
            latencyMode: .auto,
            targetFPS: 60,
            renderedFPS: 40,
            drawableWaitAvgMs: 10,
            hasCapPressure: true
        )
        #expect(second.recoveryEntered)
        #expect(policy.snapshot().recoveryActive)
    }

    @Test("Auto typing burst suppresses recovery entry despite pressure")
    func autoTypingSuppressesRecoveryEntry() {
        var policy = MirageRenderStabilityPolicy()

        _ = policy.evaluate(
            now: 100,
            latencyMode: .auto,
            targetFPS: 60,
            renderedFPS: 30,
            drawableWaitAvgMs: 24,
            hasCapPressure: true,
            typingBurstActive: true
        )
        let second = policy.evaluate(
            now: 102,
            latencyMode: .auto,
            targetFPS: 60,
            renderedFPS: 30,
            drawableWaitAvgMs: 24,
            hasCapPressure: true,
            typingBurstActive: true
        )
        #expect(!second.recoveryEntered)
        #expect(!policy.snapshot().recoveryActive)
    }

    @Test("Recovery enters after two degraded windows")
    func entersAfterTwoDegradedWindows() {
        var policy = MirageRenderStabilityPolicy()

        let first = policy.evaluate(
            now: 100,
            latencyMode: .auto,
            targetFPS: 60,
            renderedFPS: 40,
            drawableWaitAvgMs: 26
        )
        #expect(!first.recoveryEntered)
        #expect(!policy.snapshot().recoveryActive)

        let second = policy.evaluate(
            now: 102,
            latencyMode: .auto,
            targetFPS: 60,
            renderedFPS: 40,
            drawableWaitAvgMs: 26
        )
        #expect(second.recoveryEntered)
        #expect(policy.snapshot().recoveryActive)
    }

    @Test("Recovery exits only after hold and healthy streak")
    func exitsAfterHoldAndHealthyWindows() {
        var policy = MirageRenderStabilityPolicy()

        _ = policy.evaluate(
            now: 100,
            latencyMode: .auto,
            targetFPS: 60,
            renderedFPS: 40,
            drawableWaitAvgMs: 26
        )
        _ = policy.evaluate(
            now: 102,
            latencyMode: .auto,
            targetFPS: 60,
            renderedFPS: 40,
            drawableWaitAvgMs: 26
        )
        #expect(policy.snapshot().recoveryActive)

        let duringHold = policy.evaluate(
            now: 103,
            latencyMode: .auto,
            targetFPS: 60,
            renderedFPS: 60,
            drawableWaitAvgMs: 10
        )
        #expect(!duringHold.recoveryExited)
        #expect(policy.snapshot().recoveryActive)

        let firstHealthy = policy.evaluate(
            now: 104.2,
            latencyMode: .auto,
            targetFPS: 60,
            renderedFPS: 60,
            drawableWaitAvgMs: 10
        )
        #expect(!firstHealthy.recoveryExited)
        #expect(policy.snapshot().recoveryActive)

        let secondHealthy = policy.evaluate(
            now: 106.3,
            latencyMode: .auto,
            targetFPS: 60,
            renderedFPS: 60,
            drawableWaitAvgMs: 10
        )
        #expect(secondHealthy.recoveryExited)
        #expect(!policy.snapshot().recoveryActive)
    }

    @Test("Recovery cooldown blocks immediate re-entry")
    func cooldownPreventsImmediateReentry() {
        var policy = MirageRenderStabilityPolicy()

        _ = policy.evaluate(
            now: 100,
            latencyMode: .auto,
            targetFPS: 60,
            renderedFPS: 40,
            drawableWaitAvgMs: 26
        )
        _ = policy.evaluate(
            now: 102,
            latencyMode: .auto,
            targetFPS: 60,
            renderedFPS: 40,
            drawableWaitAvgMs: 26
        )
        _ = policy.evaluate(
            now: 104.2,
            latencyMode: .auto,
            targetFPS: 60,
            renderedFPS: 60,
            drawableWaitAvgMs: 10
        )
        _ = policy.evaluate(
            now: 106.3,
            latencyMode: .auto,
            targetFPS: 60,
            renderedFPS: 60,
            drawableWaitAvgMs: 10
        )
        #expect(!policy.snapshot().recoveryActive)

        let cooldownFirst = policy.evaluate(
            now: 107,
            latencyMode: .auto,
            targetFPS: 60,
            renderedFPS: 40,
            drawableWaitAvgMs: 26
        )
        let cooldownSecond = policy.evaluate(
            now: 108,
            latencyMode: .auto,
            targetFPS: 60,
            renderedFPS: 40,
            drawableWaitAvgMs: 26
        )
        #expect(!cooldownFirst.recoveryEntered)
        #expect(!cooldownSecond.recoveryEntered)
        #expect(!policy.snapshot().recoveryActive)

        _ = policy.evaluate(
            now: 110,
            latencyMode: .auto,
            targetFPS: 60,
            renderedFPS: 40,
            drawableWaitAvgMs: 26
        )
        let afterCooldown = policy.evaluate(
            now: 112,
            latencyMode: .auto,
            targetFPS: 60,
            renderedFPS: 40,
            drawableWaitAvgMs: 26
        )
        #expect(afterCooldown.recoveryEntered)
        #expect(policy.snapshot().recoveryActive)
    }

    @Test("Active recovery keeps throughput-safe in-flight cap")
    func activeRecoveryForcesSingleInFlightCap() {
        var policy = MirageRenderStabilityPolicy()

        _ = policy.evaluate(
            now: 100,
            latencyMode: .smoothest,
            targetFPS: 60,
            renderedFPS: 40,
            drawableWaitAvgMs: 26
        )
        _ = policy.evaluate(
            now: 102,
            latencyMode: .smoothest,
            targetFPS: 60,
            renderedFPS: 40,
            drawableWaitAvgMs: 26
        )
        #expect(policy.snapshot().recoveryActive)

        let decision = MirageRenderAdmissionPolicy.decision(
            latencyMode: .smoothest,
            targetFPS: 60,
            typingBurstActive: false,
            recoveryActive: policy.snapshot().recoveryActive,
            smoothestPromotionActive: policy.snapshot().smoothestPromotionActive,
            pressureActive: false
        )
        #expect(decision.inFlightCap == 2)
        #expect(decision.reason == .recovery)
    }
}
#endif
