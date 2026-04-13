//
//  InputCapturingResponderRecoveryTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/12/26.
//

#if os(iOS) || os(visionOS)
@testable import MirageKitClient
import Testing
import UIKit

@MainActor
@Suite("Input capturing responder recovery")
struct InputCapturingResponderRecoveryTests {
    typealias ScheduledOperation = @MainActor () -> Void

    @Test("Recovery skips when the capture view is detached")
    func skipsWhenDetached() {
        let decision = InputCapturingResponderRecoveryPolicy.decision(
            for: makeContext(hasWindow: false),
            trigger: .interaction
        )

        #expect(decision == .skip(.noWindow))
    }

    @Test("Recovery skips when the window is not key")
    func skipsWhenWindowIsNotKey() {
        let decision = InputCapturingResponderRecoveryPolicy.decision(
            for: makeContext(isKeyWindow: false),
            trigger: .interaction
        )

        #expect(decision == .skip(.windowNotKey))
    }

    @Test("Recovery skips interaction requests while the scene is inactive")
    func skipsInteractionWhenSceneIsInactive() {
        let decision = InputCapturingResponderRecoveryPolicy.decision(
            for: makeContext(sceneActivationState: .foregroundInactive),
            trigger: .interaction
        )

        #expect(decision == .skip(.sceneNotForegroundActive))
    }

    @Test("Recovery skips when the intended responder is already active")
    func skipsWhenTargetAlreadyFirstResponder() {
        let decision = InputCapturingResponderRecoveryPolicy.decision(
            for: makeContext(targetIsFirstResponder: true),
            trigger: .interaction
        )

        #expect(decision == .skip(.targetAlreadyFirstResponder))
    }

    @Test("Recovery proceeds for an active key window")
    func recoversForActiveKeyWindow() {
        let decision = InputCapturingResponderRecoveryPolicy.decision(
            for: makeContext(),
            trigger: .interaction
        )

        #expect(decision == .recover)
    }

    @Test("Key-window activation triggers recovery during foreground transitions")
    func keyWindowActivationAllowsRecoveryDuringTransition() {
        let decision = InputCapturingResponderRecoveryPolicy.decision(
            for: makeContext(sceneActivationState: .foregroundInactive),
            trigger: .windowDidBecomeKey
        )

        #expect(decision == .recover)
    }

    @Test("Target selection prefers hardware capture when a hardware keyboard is present")
    func targetSelectionPrefersCaptureViewForHardwareKeyboard() {
        let target = InputCapturingResponderRecoveryPolicy.target(
            softwareKeyboardVisible: true,
            hardwareKeyboardPresent: true
        )

        #expect(target == .captureView)
    }

    @Test("Target selection prefers the software keyboard field when intentionally shown")
    func targetSelectionPrefersSoftwareKeyboardField() {
        let target = InputCapturingResponderRecoveryPolicy.target(
            softwareKeyboardVisible: true,
            hardwareKeyboardPresent: false
        )

        #expect(target == .softwareKeyboardField)
    }

    @Test("Controller retries once when the first recovery attempt lands before the window is key")
    func controllerRetriesOnceForKeyWindowTransition() {
        var scheduledDelays: [Duration] = []
        var scheduledOperations: [ScheduledOperation] = []
        var snapshots: [
            (
                target: InputCapturingResponderTarget,
                context: InputCapturingResponderRecoveryContext
            )
        ] = [
            (
                target: .captureView,
                context: makeContext(isKeyWindow: false)
            ),
            (
                target: .captureView,
                context: makeContext()
            ),
        ]
        var attemptedTargets: [InputCapturingResponderTarget] = []

        let controller = InputCapturingResponderRecoveryController(
            scheduler: InputCapturingResponderRecoveryScheduler(
                schedule: { delay, operation in
                    scheduledDelays.append(delay)
                    scheduledOperations.append(operation)
                    return Task {}
                }
            ),
            contextProvider: { _ in
                if snapshots.count > 1 {
                    return snapshots.removeFirst()
                }
                return snapshots[0]
            },
            attemptHandler: { target in
                attemptedTargets.append(target)
                return true
            },
            logHandler: { _, _, _, _, _, _ in }
        )

        controller.requestRecovery(.didMoveToWindow)

        #expect(scheduledDelays.count == 1)
        #expect(scheduledDelays[0] == .zero)
        #expect(attemptedTargets.isEmpty)

        let firstOperation = scheduledOperations.removeFirst()
        firstOperation()

        #expect(scheduledDelays.count == 2)
        #expect(attemptedTargets.isEmpty)

        let secondOperation = scheduledOperations.removeFirst()
        secondOperation()

        #expect(attemptedTargets == [.captureView])
    }

    private func makeContext(
        hasWindow: Bool = true,
        isKeyWindow: Bool = true,
        sceneActivationState: UISceneActivationState? = .foregroundActive,
        targetIsFirstResponder: Bool = false
    ) -> InputCapturingResponderRecoveryContext {
        InputCapturingResponderRecoveryContext(
            hasWindow: hasWindow,
            isKeyWindow: isKeyWindow,
            sceneActivationState: sceneActivationState,
            targetIsFirstResponder: targetIsFirstResponder
        )
    }
}
#endif
