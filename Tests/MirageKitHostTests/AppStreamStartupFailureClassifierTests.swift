//
//  AppStreamStartupFailureClassifierTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/26/26.
//
//  Classifier coverage for retry vs terminal app-window startup failures.
//

@testable import MirageKit
@testable import MirageKitHost
import Testing

#if os(macOS)
@Suite("App Stream Startup Failure Classifier")
struct AppStreamStartupFailureClassifierTests {
    private struct StubError: LocalizedError {
        let description: String

        var errorDescription: String? { description }
    }

    @Test("Virtual-display allocation failures are terminal and inventory-hidden")
    func virtualDisplayAllocationFailureIsTerminal() {
        let error = WindowStreamStartError.virtualDisplayStartFailed(
            "Failed to create virtual display: Virtual display failed activation (Retina + 1x fallback)"
        )

        #expect(!AppStreamStartupFailureClassifier.isRetryableWindowStartupError(error))
        #expect(AppStreamStartupFailureClassifier.shouldHideFailedWindowInInventory(error))
        #expect(AppStreamStartupFailureClassifier.isNonRetryableVirtualDisplayAllocationError(error))
    }

    @Test("SpawnProxy descriptor failures are terminal and inventory-hidden")
    func spawnProxyDescriptorFailureIsTerminal() {
        let error = StubError(
            description: "-[VirtualDisplayClient pluginWithOptions:]: spawnProxy message error kr=0x5((os/kern) failure)"
        )

        #expect(!AppStreamStartupFailureClassifier.isRetryableWindowStartupError(error))
        #expect(AppStreamStartupFailureClassifier.shouldHideFailedWindowInInventory(error))
    }

    @Test("Dedicated virtual-display startup failures remain retryable when allocation did not fail")
    func genericDedicatedVirtualDisplayFailureIsRetryable() {
        let error = StubError(
            description: "Dedicated virtual display start failed: window disappeared before stream startup"
        )

        #expect(AppStreamStartupFailureClassifier.isRetryableWindowStartupError(error))
        #expect(!AppStreamStartupFailureClassifier.shouldHideFailedWindowInInventory(error))
    }

    @Test("Window-not-found and timeout remain retryable")
    func windowNotFoundAndTimeoutAreRetryable() {
        #expect(AppStreamStartupFailureClassifier.isRetryableWindowStartupError(MirageError.windowNotFound))
        #expect(AppStreamStartupFailureClassifier.isRetryableWindowStartupError(MirageError.timeout))
    }

    @Test("Protocol errors are non-retryable")
    func protocolErrorsAreNonRetryable() {
        let error = MirageError.protocolError("invalid app selection")

        #expect(!AppStreamStartupFailureClassifier.isRetryableWindowStartupError(error))
        #expect(!AppStreamStartupFailureClassifier.shouldHideFailedWindowInInventory(error))
    }
}
#endif
