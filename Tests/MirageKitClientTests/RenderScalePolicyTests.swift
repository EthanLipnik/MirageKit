//
//  RenderScalePolicyTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/13/26.
//

@testable import MirageKitClient
import Testing

#if os(macOS)
@Suite("Render Scale Policy")
struct RenderScalePolicyTests {
    @Test("Auto downscales after sustained degraded windows")
    func autoDownscaleAfterSustainedDegrade() {
        var policy = MirageRenderScalePolicy()

        _ = policy.evaluate(
            now: 100,
            latencyMode: .auto,
            targetFPS: 60,
            renderedFPS: 45,
            drawableWaitAvgMs: 24,
            typingBurstActive: false
        )
        _ = policy.evaluate(
            now: 101,
            latencyMode: .auto,
            targetFPS: 60,
            renderedFPS: 45,
            drawableWaitAvgMs: 24,
            typingBurstActive: false
        )
        let third = policy.evaluate(
            now: 102,
            latencyMode: .auto,
            targetFPS: 60,
            renderedFPS: 45,
            drawableWaitAvgMs: 24,
            typingBurstActive: false
        )

        #expect(third.direction == .down)
        #expect(policy.snapshot().scale == 0.9)
    }

    @Test("Auto upscales after healthy streak and step interval")
    func autoUpscaleAfterHealthyStreak() {
        var policy = MirageRenderScalePolicy()

        for index in 0 ..< 3 {
            _ = policy.evaluate(
                now: 100 + Double(index),
                latencyMode: .auto,
                targetFPS: 60,
                renderedFPS: 45,
                drawableWaitAvgMs: 24,
                typingBurstActive: false
            )
        }
        #expect(policy.snapshot().scale == 0.9)

        var now: CFAbsoluteTime = 104.5
        var sawUpscale = false
        for _ in 0 ..< 5 {
            let transition = policy.evaluate(
                now: now,
                latencyMode: .auto,
                targetFPS: 60,
                renderedFPS: 60,
                drawableWaitAvgMs: 7,
                typingBurstActive: false
            )
            if transition.direction == .up {
                sawUpscale = true
            }
            now += 0.5
        }
        let finalTransition = policy.evaluate(
            now: 107.0,
            latencyMode: .auto,
            targetFPS: 60,
            renderedFPS: 60,
            drawableWaitAvgMs: 7,
            typingBurstActive: false
        )
        if finalTransition.direction == .up {
            sawUpscale = true
        }

        #expect(sawUpscale)
        #expect(policy.snapshot().scale == 1.0)
    }

    @Test("Typing burst blocks upscale but allows downscale")
    func typingBurstBlocksUpscale() {
        var policy = MirageRenderScalePolicy()

        for index in 0 ..< 3 {
            _ = policy.evaluate(
                now: 100 + Double(index),
                latencyMode: .auto,
                targetFPS: 60,
                renderedFPS: 45,
                drawableWaitAvgMs: 24,
                typingBurstActive: true
            )
        }
        #expect(policy.snapshot().scale == 0.9)

        var now: CFAbsoluteTime = 104.5
        for _ in 0 ..< 6 {
            let transition = policy.evaluate(
                now: now,
                latencyMode: .auto,
                targetFPS: 60,
                renderedFPS: 60,
                drawableWaitAvgMs: 7,
                typingBurstActive: true
            )
            #expect(transition.direction != .up)
            now += 0.5
        }
        #expect(policy.snapshot().scale == 0.9)
    }

    @Test("Lowest latency downscales under sustained compositor pressure")
    func lowestLatencyDownscalesAfterSustainedDegrade() {
        var policy = MirageRenderScalePolicy()

        _ = policy.evaluate(
            now: 100,
            latencyMode: .lowestLatency,
            targetFPS: 60,
            renderedFPS: 45,
            drawableWaitAvgMs: 24,
            typingBurstActive: false
        )
        _ = policy.evaluate(
            now: 101,
            latencyMode: .lowestLatency,
            targetFPS: 60,
            renderedFPS: 45,
            drawableWaitAvgMs: 24,
            typingBurstActive: false
        )
        let third = policy.evaluate(
            now: 102,
            latencyMode: .lowestLatency,
            targetFPS: 60,
            renderedFPS: 45,
            drawableWaitAvgMs: 24,
            typingBurstActive: false
        )

        #expect(third.direction == .down)
        #expect(policy.snapshot().scale == 0.9)
    }

    @Test("Lowest latency does not downscale on low FPS alone when drawable wait is healthy")
    func lowestLatencyDoesNotDownscaleOnLowFPSWithoutDrawablePressure() {
        var policy = MirageRenderScalePolicy()

        _ = policy.evaluate(
            now: 100,
            latencyMode: .lowestLatency,
            targetFPS: 60,
            renderedFPS: 42,
            drawableWaitAvgMs: 1.0,
            typingBurstActive: false
        )
        _ = policy.evaluate(
            now: 101,
            latencyMode: .lowestLatency,
            targetFPS: 60,
            renderedFPS: 42,
            drawableWaitAvgMs: 1.0,
            typingBurstActive: false
        )
        let third = policy.evaluate(
            now: 102,
            latencyMode: .lowestLatency,
            targetFPS: 60,
            renderedFPS: 42,
            drawableWaitAvgMs: 1.0,
            typingBurstActive: false
        )

        #expect(third.direction == nil)
        #expect(policy.snapshot().scale == 1.0)
    }
}
#endif
