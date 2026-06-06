//
//  InputCapturingResponderRecoveryTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/12/26.
//

#if os(iOS) || os(visionOS)
import MirageKit
@testable import MirageKitClient
import Testing
import UIKit
import MirageInput

@MainActor
@Suite("Input capturing responder recovery")
struct InputCapturingResponderRecoveryTests {
    typealias ScheduledOperation = @MainActor () -> Void

    @Test("Hardware keyboard presence keeps software keyboard state while targeting capture view")
    func hardwareKeyboardPresenceKeepsSoftwareStateWhileTargetingCaptureView() {
        let view = InputCapturingView(frame: .zero)
        var hardwarePresenceEvents: [Bool] = []
        view.softwareKeyboardVisible = true
        view.onHardwareKeyboardPresenceChanged = { hardwarePresenceEvents.append($0) }

        view.updateHardwareKeyboardPresence(true)

        #expect(view.hardwareKeyboardPresent)
        #expect(view.softwareKeyboardVisible)
        #expect(view.responderRecoveryTarget == .captureView)
        #expect(hardwarePresenceEvents == [true])
    }

    @Test("Software keyboard targets input field without hardware keyboard")
    func softwareKeyboardTargetsInputFieldWithoutHardwareKeyboard() {
        let view = InputCapturingView(frame: .zero)

        view.softwareKeyboardVisible = true

        #expect(!view.hardwareKeyboardPresent)
        #expect(view.responderRecoveryTarget == .softwareKeyboardField)
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
            contextProvider: {
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

    @Test("Interaction recovery is skipped when the target is already first responder")
    func interactionRecoverySkippedWhenTargetAlreadyFirstResponder() {
        var scheduledDelays: [Duration] = []
        let controller = InputCapturingResponderRecoveryController(
            scheduler: InputCapturingResponderRecoveryScheduler(
                schedule: { delay, _ in
                    scheduledDelays.append(delay)
                    return Task {}
                }
            ),
            contextProvider: {
                (
                    target: .captureView,
                    context: makeContext(targetIsFirstResponder: true)
                )
            },
            attemptHandler: { _ in true },
            logHandler: { _, _, _, _, _, _ in }
        )

        controller.requestRecovery(.interaction)
        controller.requestRecovery(.interaction)

        #expect(scheduledDelays.isEmpty)
    }

    @Test("Interaction recovery is throttled")
    func interactionRecoveryIsThrottled() {
        var now: CFAbsoluteTime = 100
        var scheduledDelays: [Duration] = []
        let controller = InputCapturingResponderRecoveryController(
            scheduler: InputCapturingResponderRecoveryScheduler(
                schedule: { delay, _ in
                    scheduledDelays.append(delay)
                    return Task {}
                }
            ),
            nowProvider: { now },
            contextProvider: {
                (
                    target: .captureView,
                    context: makeContext(targetIsFirstResponder: false)
                )
            },
            attemptHandler: { _ in true },
            logHandler: { _, _, _, _, _, _ in }
        )

        controller.requestRecovery(.interaction)
        now += 0.100
        controller.requestRecovery(.interaction)
        now += 0.250
        controller.requestRecovery(.interaction)

        #expect(scheduledDelays == [.zero, .zero])
    }

    @Test("Interaction recovery does not replace a pending lifecycle retry")
    func interactionRecoveryDoesNotReplacePendingLifecycleRetry() {
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
                context: makeContext(targetIsFirstResponder: false)
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
            contextProvider: {
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
        scheduledOperations.removeFirst()()

        #expect(scheduledDelays == [.zero, .milliseconds(150)])
        controller.requestRecovery(.interaction)
        #expect(scheduledDelays == [.zero, .milliseconds(150)])

        scheduledOperations.removeFirst()()
        #expect(attemptedTargets == [.captureView])
    }

    @Test("Activation recovery waits for foreground-active scene")
    func activationRecoveryWaitsForForegroundActiveScene() {
        #expect(
            !inputCapturingCanApplyPendingActivationHandling(
                hasWindow: true,
                sceneActivationState: .background
            )
        )
        #expect(
            !inputCapturingCanApplyPendingActivationHandling(
                hasWindow: true,
                sceneActivationState: .foregroundInactive
            )
        )
        #expect(
            inputCapturingCanApplyPendingActivationHandling(
                hasWindow: true,
                sceneActivationState: .foregroundActive
            )
        )
    }

    @Test("Display activation handling can resume in foreground-inactive scene")
    func displayActivationHandlingCanResumeInForegroundInactiveScene() {
        #expect(
            inputCapturingCanApplyPendingDisplayActivationHandling(
                hasWindow: true,
                sceneActivationState: .foregroundInactive
            )
        )
        #expect(
            inputCapturingCanApplyPendingDisplayActivationHandling(
                hasWindow: true,
                sceneActivationState: .foregroundActive
            )
        )
        #expect(
            !inputCapturingCanApplyPendingDisplayActivationHandling(
                hasWindow: true,
                sceneActivationState: .background
            )
        )
    }

    @Test("Desktop stream start and transition triggers can recover during activation")
    func desktopStreamTriggersCanRecoverDuringActivation() {
        let activationContext = makeContext(sceneActivationState: .foregroundInactive)

        #expect(
            InputCapturingResponderRecoveryPolicy.decision(
                for: activationContext,
                trigger: .desktopStreamStarted
            ) == .recover
        )
        #expect(
            InputCapturingResponderRecoveryPolicy.decision(
                for: activationContext,
                trigger: .desktopTransitionCommitted
            ) == .recover
        )
    }

    @Test("Software keyboard input sends events while hardware keyboard is present")
    func softwareKeyboardInputSendsEventsWhileHardwareKeyboardIsPresent() {
        let view = InputCapturingView(frame: .zero)
        var events: [MirageInput.MirageInputEvent] = []
        view.onInputEvent = { events.append($0) }
        view.updateHardwareKeyboardPresence(true)

        view.handleSoftwareKeyboardInsertText("a")
        view.handleSoftwareKeyboardDeleteBackward()

        let keyEvents = events.compactMap { event -> MirageInput.MirageKeyEvent? in
            switch event {
            case let .keyDown(key), let .keyUp(key):
                key
            default:
                nil
            }
        }
        #expect(keyEvents.count == 4)
        #expect(keyEvents[0].characters == "a")
        #expect(keyEvents[0].charactersIgnoringModifiers == "a")
        #expect(keyEvents[2].keyCode == 0x33)
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
