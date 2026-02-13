//
//  AutoLatencyRecoveryTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/13/26.
//
//  Coverage for auto-latency low-FPS recovery state machine behavior.
//

@testable import MirageKitHost
import MirageKit
import Testing

#if os(macOS)
@Suite("Auto Latency Recovery")
struct AutoLatencyRecoveryTests {
    @Test("Recovery enters after two unhealthy windows and clamps in-flight and quality")
    func entersRecoveryAndClampsPolicy() async {
        let context = makeContext()
        let budget = 1000.0 / 60.0

        await context.updateInFlightLimitIfNeeded(
            captureFPS: 60,
            encodeFPS: 60,
            averageEncodeMs: budget * 0.7,
            pendingCount: 0,
            at: 1.0
        )
        await context.updateInFlightLimitIfNeeded(
            captureFPS: 60,
            encodeFPS: 60,
            averageEncodeMs: budget * 0.7,
            pendingCount: 0,
            at: 3.0
        )
        let preRecovery = await context.autoRecoverySnapshot()
        #expect(preRecovery.maxInFlightFrames == 2)

        await context.updateInFlightLimitIfNeeded(
            captureFPS: 42,
            encodeFPS: 41,
            averageEncodeMs: budget * 1.5,
            pendingCount: 1,
            at: 10.0
        )
        let firstWindow = await context.autoRecoverySnapshot()
        #expect(!firstWindow.active)

        await context.updateInFlightLimitIfNeeded(
            captureFPS: 41,
            encodeFPS: 40,
            averageEncodeMs: budget * 1.6,
            pendingCount: 1,
            at: 12.1
        )
        let entered = await context.autoRecoverySnapshot()
        #expect(entered.active)
        #expect(entered.maxInFlightFrames == 1)
        #expect(entered.qualityCeiling <= 0.58 + 0.0001)
        #expect(entered.activeQuality <= entered.qualityCeiling + 0.0001)
    }

    @Test("Recovery holds minimum duration and exits after two healthy windows")
    func recoveryHoldAndExitPolicy() async {
        let context = makeContext()
        let budget = 1000.0 / 60.0

        await context.updateInFlightLimitIfNeeded(
            captureFPS: 40,
            encodeFPS: 40,
            averageEncodeMs: budget * 1.5,
            pendingCount: 1,
            at: 20.0
        )
        await context.updateInFlightLimitIfNeeded(
            captureFPS: 40,
            encodeFPS: 40,
            averageEncodeMs: budget * 1.5,
            pendingCount: 1,
            at: 22.1
        )
        let entered = await context.autoRecoverySnapshot()
        #expect(entered.active)

        await context.updateInFlightLimitIfNeeded(
            captureFPS: 60,
            encodeFPS: 60,
            averageEncodeMs: budget,
            pendingCount: 0,
            at: 23.0
        )
        let stillHolding = await context.autoRecoverySnapshot()
        #expect(stillHolding.active)
        #expect(stillHolding.healthyStreak == 0)

        await context.updateInFlightLimitIfNeeded(
            captureFPS: 60,
            encodeFPS: 60,
            averageEncodeMs: budget,
            pendingCount: 0,
            at: 24.2
        )
        let firstHealthy = await context.autoRecoverySnapshot()
        #expect(firstHealthy.active)
        #expect(firstHealthy.healthyStreak == 1)

        await context.updateInFlightLimitIfNeeded(
            captureFPS: 60,
            encodeFPS: 60,
            averageEncodeMs: budget,
            pendingCount: 0,
            at: 26.3
        )
        let exited = await context.autoRecoverySnapshot()
        #expect(!exited.active)
        #expect(exited.cooldownUntil > 26.3)
    }

    @Test("Recovery cooldown prevents immediate re-entry")
    func recoveryCooldownPolicy() async {
        let context = makeContext()
        let budget = 1000.0 / 60.0

        await context.updateInFlightLimitIfNeeded(
            captureFPS: 40,
            encodeFPS: 40,
            averageEncodeMs: budget * 1.5,
            pendingCount: 1,
            at: 30.0
        )
        await context.updateInFlightLimitIfNeeded(
            captureFPS: 40,
            encodeFPS: 40,
            averageEncodeMs: budget * 1.5,
            pendingCount: 1,
            at: 32.1
        )
        await context.updateInFlightLimitIfNeeded(
            captureFPS: 60,
            encodeFPS: 60,
            averageEncodeMs: budget,
            pendingCount: 0,
            at: 34.2
        )
        await context.updateInFlightLimitIfNeeded(
            captureFPS: 60,
            encodeFPS: 60,
            averageEncodeMs: budget,
            pendingCount: 0,
            at: 36.3
        )
        let exited = await context.autoRecoverySnapshot()
        #expect(!exited.active)

        await context.updateInFlightLimitIfNeeded(
            captureFPS: 40,
            encodeFPS: 40,
            averageEncodeMs: budget * 1.5,
            pendingCount: 1,
            at: 37.0
        )
        await context.updateInFlightLimitIfNeeded(
            captureFPS: 40,
            encodeFPS: 40,
            averageEncodeMs: budget * 1.5,
            pendingCount: 1,
            at: 38.0
        )
        let blockedByCooldown = await context.autoRecoverySnapshot()
        #expect(!blockedByCooldown.active)

        await context.updateInFlightLimitIfNeeded(
            captureFPS: 40,
            encodeFPS: 40,
            averageEncodeMs: budget * 1.5,
            pendingCount: 1,
            at: 39.5
        )
        await context.updateInFlightLimitIfNeeded(
            captureFPS: 40,
            encodeFPS: 40,
            averageEncodeMs: budget * 1.5,
            pendingCount: 1,
            at: 41.6
        )
        let reentered = await context.autoRecoverySnapshot()
        #expect(reentered.active)
    }

    private func makeContext() -> StreamContext {
        let config = MirageEncoderConfiguration(
            targetFrameRate: 60,
            keyFrameInterval: 1800,
            colorSpace: .displayP3,
            pixelFormat: .p010,
            bitrate: 50_000_000
        )
        return StreamContext(
            streamID: 77,
            windowID: 0,
            encoderConfig: config,
            latencyMode: .auto
        )
    }
}
#endif
