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

    @Test("Window already bound conflicts are non-retryable")
    func windowAlreadyBoundConflictsAreNonRetryable() {
        let error = WindowStreamStartError.windowAlreadyBound(
            windowID: 404,
            existingStreamID: 9
        )

        #expect(!AppStreamStartupFailureClassifier.isRetryableWindowStartupError(error))
        #expect(!AppStreamStartupFailureClassifier.shouldHideFailedWindowInInventory(error))
    }

    @Test("Owner conflict and mismatch details are non-retryable")
    func ownerConflictAndMismatchDetailsAreNonRetryable() {
        let ownerConflict = WindowStreamStartError.virtualDisplayStartFailed(
            "Window 18769 already owned by stream 2; requested stream 3"
        )
        let ownerMismatch = WindowStreamStartError.virtualDisplayStartFailed(
            "Window 18769 restore owner mismatch expected stream 3, actual stream 2"
        )

        #expect(!AppStreamStartupFailureClassifier.isRetryableWindowStartupError(ownerConflict))
        #expect(!AppStreamStartupFailureClassifier.isRetryableWindowStartupError(ownerMismatch))
        #expect(!AppStreamStartupFailureClassifier.shouldHideFailedWindowInInventory(ownerConflict))
        #expect(!AppStreamStartupFailureClassifier.shouldHideFailedWindowInInventory(ownerMismatch))
    }
}
#endif
