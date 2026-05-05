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

@MainActor
@Suite("Input capturing responder recovery")
struct InputCapturingResponderRecoveryTests {
    typealias ScheduledOperation = @MainActor () -> Void

    @Test("Hardware keyboard presence change preserves software keyboard state and requests recovery")
    func hardwareKeyboardPresenceChangePreservesSoftwareStateAndRequestsRecovery() {
        let view = InputCapturingView(frame: .zero)
        var requestedTriggers: [InputCapturingResponderRecoveryTrigger] = []
        var hardwarePresenceEvents: [Bool] = []
        view.softwareKeyboardVisible = true
        view.onResponderRecoveryRequestedForTesting = { requestedTriggers.append($0) }
        view.onHardwareKeyboardPresenceChanged = { hardwarePresenceEvents.append($0) }

        view.updateHardwareKeyboardPresence(true)

        #expect(view.hardwareKeyboardPresent)
        #expect(view.softwareKeyboardVisible)
        #expect(view.responderRecoveryTarget() == .softwareKeyboardField)
        #expect(requestedTriggers == [.hardwareKeyboardPresenceChanged])
        #expect(hardwarePresenceEvents == [true])
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

    @Test("Software keyboard input sends events while hardware keyboard is present")
    func softwareKeyboardInputSendsEventsWhileHardwareKeyboardIsPresent() {
        let view = InputCapturingView(frame: .zero)
        var events: [MirageInputEvent] = []
        view.onInputEvent = { events.append($0) }
        view.updateHardwareKeyboardPresence(true)

        view.handleSoftwareKeyboardInsertText("a")
        view.handleSoftwareKeyboardDeleteBackward()

        let keyEvents = events.compactMap { event -> MirageKeyEvent? in
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
