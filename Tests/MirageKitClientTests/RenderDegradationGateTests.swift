//
//  RenderDegradationGateTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/17/26.
//
//  Coverage for render scale degradation gating.
//

@testable import MirageKitClient
import Testing

@Suite("Render Degradation Gate")
struct RenderDegradationGateTests {
    @Test("Gate OFF keeps render scale fixed")
    func gateOffKeepsScaleFixed() {
        var controller = MirageRenderLoopScaleController()
        let frameBudgetMs = 16.67

        for now in stride(from: 0.0, through: 5.0, by: 0.1) {
            let transition = controller.evaluate(
                now: now,
                allowDegradation: false,
                frameBudgetMs: frameBudgetMs,
                drawableWaitMs: 40
            )
            #expect(transition == nil)
            #expect(controller.currentScale == 1.0)
        }
    }

    @Test("Gate ON applies controlled scale ladder transitions")
    func gateOnAppliesScaleLadder() {
        var controller = MirageRenderLoopScaleController()
        let frameBudgetMs = 16.67

        var firstDown: MirageRenderLoopScaleTransition?
        for now in [0.0, 0.1, 0.2] {
            firstDown = controller.evaluate(
                now: now,
                allowDegradation: true,
                frameBudgetMs: frameBudgetMs,
                drawableWaitMs: 40
            )
        }

        #expect(firstDown?.direction == .down)
        #expect(firstDown?.newScale == 0.9)
        #expect(controller.currentScale == 0.9)

        var secondDown: MirageRenderLoopScaleTransition?
        for now in [2.3, 2.4, 2.5] {
            secondDown = controller.evaluate(
                now: now,
                allowDegradation: true,
                frameBudgetMs: frameBudgetMs,
                drawableWaitMs: 40
            )
        }

        #expect(secondDown?.direction == .down)
        #expect(secondDown?.newScale == 0.8)
        #expect(controller.currentScale == 0.8)

        var firstUp: MirageRenderLoopScaleTransition?
        for now in [4.7, 4.8, 4.9, 5.0, 5.1] {
            firstUp = controller.evaluate(
                now: now,
                allowDegradation: true,
                frameBudgetMs: frameBudgetMs,
                drawableWaitMs: 4
            )
        }

        #expect(firstUp?.direction == .up)
        #expect(firstUp?.newScale == 0.9)
        #expect(controller.currentScale == 0.9)
    }

    @Test("Disabling gate resets degraded scale to baseline")
    func disablingGateResetsScale() {
        var controller = MirageRenderLoopScaleController()
        let frameBudgetMs = 16.67

        for now in [0.0, 0.1, 0.2] {
            _ = controller.evaluate(
                now: now,
                allowDegradation: true,
                frameBudgetMs: frameBudgetMs,
                drawableWaitMs: 40
            )
        }

        #expect(controller.currentScale == 0.9)

        let reset = controller.evaluate(
            now: 0.3,
            allowDegradation: false,
            frameBudgetMs: frameBudgetMs,
            drawableWaitMs: 40
        )

        #expect(reset == nil)
        #expect(controller.currentScale == 1.0)
    }
}
