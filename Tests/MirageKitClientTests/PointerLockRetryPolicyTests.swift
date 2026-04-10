//
//  PointerLockRetryPolicyTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/9/26.
//

@testable import MirageKitClient
import Testing

#if os(macOS)
@Suite("Pointer Lock Retry Policy")
struct PointerLockRetryPolicyTests {
    @Test("Requested lock keeps retrying until a mouse is present and the scene locks")
    func requestedLockKeepsRetryingUntilResolved() {
        #expect(
            PointerLockRetryPolicy.shouldRetryEvaluation(
                pointerLockRequested: true,
                hasMouse: false,
                isLocked: false
            )
        )
        #expect(
            PointerLockRetryPolicy.shouldRetryEvaluation(
                pointerLockRequested: true,
                hasMouse: true,
                isLocked: false
            )
        )
        #expect(
            !PointerLockRetryPolicy.shouldRetryEvaluation(
                pointerLockRequested: true,
                hasMouse: true,
                isLocked: true
            )
        )
    }

    @Test("Requested unlock keeps retrying until the scene reports unlocked")
    func requestedUnlockKeepsRetryingUntilResolved() {
        #expect(
            PointerLockRetryPolicy.shouldRetryEvaluation(
                pointerLockRequested: false,
                hasMouse: true,
                isLocked: true
            )
        )
        #expect(
            !PointerLockRetryPolicy.shouldRetryEvaluation(
                pointerLockRequested: false,
                hasMouse: true,
                isLocked: false
            )
        )
    }
}
#endif
