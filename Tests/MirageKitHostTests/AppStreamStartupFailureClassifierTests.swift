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
import Foundation
import MirageCore

#if os(macOS)
@Suite("App Stream Startup Failure Classifier")
struct AppStreamStartupFailureClassifierTests {
    @Test("Virtual-display allocation failures are terminal and inventory-hidden")
    func virtualDisplayAllocationFailureIsTerminal() {
        let error = WindowStreamStartError.virtualDisplayStartFailed(
            code: .virtualDisplayCreationFailed,
            details: "Virtual display activation failed"
        )

        #expect(!AppStreamStartupFailureClassifier.isRetryableWindowStartupError(error))
        #expect(AppStreamStartupFailureClassifier.isNonRetryableVirtualDisplayAllocationError(error))
    }

    @Test("SpawnProxy descriptor failures are terminal and inventory-hidden")
    func spawnProxyDescriptorFailureIsTerminal() {
        let error = SharedVirtualDisplayManager.SharedDisplayError.creationFailed(
            "SpawnProxy descriptor allocation failed"
        )

        #expect(!AppStreamStartupFailureClassifier.isRetryableWindowStartupError(error))
        #expect(AppStreamStartupFailureClassifier.isNonRetryableVirtualDisplayAllocationError(error))
    }

    @Test("Dedicated virtual-display startup failures remain retryable when allocation did not fail")
    func genericDedicatedVirtualDisplayFailureIsRetryable() {
        let error = WindowStreamStartError.virtualDisplayStartFailed(
            code: .unknown,
            details: "Dedicated virtual display start failed"
        )

        #expect(AppStreamStartupFailureClassifier.isRetryableWindowStartupError(error))
        #expect(!AppStreamStartupFailureClassifier.isNonRetryableVirtualDisplayAllocationError(error))
    }

    @Test("ScreenCaptureKit visibility delays remain retryable")
    func screenCaptureKitVisibilityDelayIsRetryable() {
        let error = SharedVirtualDisplayManager.SharedDisplayError.screenCaptureKitVisibilityDelayed(101)

        #expect(AppStreamStartupFailureClassifier.isRetryableWindowStartupError(error))
        #expect(!AppStreamStartupFailureClassifier.isNonRetryableVirtualDisplayAllocationError(error))
    }

    @Test("Recoverable CoreGraphics virtual-display startup errors stay retryable")
    func recoverableCoreGraphicsVirtualDisplayFailureStaysRetryable() {
        let error = NSError(domain: "CoreGraphicsErrorDomain", code: 1003)
        let failureCode = windowStreamStartFailureCode(for: error)
        let wrappedError = WindowStreamStartError.virtualDisplayStartFailed(
            code: failureCode,
            details: error.localizedDescription
        )

        #expect(failureCode == .windowPlacementFailed)
        #expect(AppStreamStartupFailureClassifier.isRetryableWindowStartupError(wrappedError))
        #expect(!AppStreamStartupFailureClassifier.isNonRetryableVirtualDisplayAllocationError(wrappedError))
    }

    @Test("Window-not-found and timeout remain retryable")
    func windowNotFoundAndTimeoutAreRetryable() {
        #expect(AppStreamStartupFailureClassifier.isRetryableWindowStartupError(MirageCore.MirageError.windowNotFound))
        #expect(AppStreamStartupFailureClassifier.isRetryableWindowStartupError(MirageCore.MirageError.timeout))
    }

    @Test("Protocol errors are non-retryable")
    func protocolErrorsAreNonRetryable() {
        let error = MirageCore.MirageError.protocolError("invalid app selection")

        #expect(!AppStreamStartupFailureClassifier.isRetryableWindowStartupError(error))
        #expect(!AppStreamStartupFailureClassifier.isNonRetryableVirtualDisplayAllocationError(error))
    }

    @Test("Window already bound conflicts are non-retryable")
    func windowAlreadyBoundConflictsAreNonRetryable() {
        let error = WindowStreamStartError.windowAlreadyBound(
            windowID: 404,
            existingStreamID: 9
        )
        let startupRaceError = WindowStreamStartError.windowStartupInProgress(windowID: 405)

        #expect(!AppStreamStartupFailureClassifier.isRetryableWindowStartupError(error))
        #expect(!AppStreamStartupFailureClassifier.isNonRetryableVirtualDisplayAllocationError(error))
        #expect(!AppStreamStartupFailureClassifier.isRetryableWindowStartupError(startupRaceError))
        #expect(!AppStreamStartupFailureClassifier.isNonRetryableVirtualDisplayAllocationError(startupRaceError))
        #expect(windowStreamStartFailureCode(for: startupRaceError) == .windowAlreadyBound)
    }

    @Test("Owner conflict and mismatch details are non-retryable")
    func ownerConflictAndMismatchDetailsAreNonRetryable() {
        let ownerConflict = WindowStreamStartError.virtualDisplayStartFailed(
            code: .windowOwnerConflict,
            details: "Window already owned by another stream"
        )
        let ownerMismatch = WindowStreamStartError.virtualDisplayStartFailed(
            code: .windowOwnerMismatch,
            details: "Window restore owner mismatch"
        )

        #expect(!AppStreamStartupFailureClassifier.isRetryableWindowStartupError(ownerConflict))
        #expect(!AppStreamStartupFailureClassifier.isRetryableWindowStartupError(ownerMismatch))
        #expect(!AppStreamStartupFailureClassifier.isNonRetryableVirtualDisplayAllocationError(ownerConflict))
        #expect(!AppStreamStartupFailureClassifier.isNonRetryableVirtualDisplayAllocationError(ownerMismatch))
    }
}
#endif
