//
//  InputCapturingResponderRecovery.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/12/26.
//

#if os(iOS) || os(visionOS)
import UIKit

enum InputCapturingResponderTarget: String {
    case captureView = "capture_view"
    case softwareKeyboardField = "software_keyboard_field"
}

enum InputCapturingResponderRecoveryTrigger: String {
    case didMoveToWindow = "did_move_to_window"
    case applicationDidBecomeActive = "application_did_become_active"
    case sceneDidActivate = "scene_did_activate"
    case sceneWillEnterForeground = "scene_will_enter_foreground"
    case windowDidBecomeKey = "window_did_become_key"
    case interaction = "interaction"
}

struct InputCapturingResponderRecoveryContext: Equatable {
    let hasWindow: Bool
    let isKeyWindow: Bool
    let sceneActivationState: UIScene.ActivationState?
    let targetIsFirstResponder: Bool
}

enum InputCapturingResponderRecoverySkipReason: String, Equatable {
    case noWindow = "no_window"
    case windowNotKey = "window_not_key"
    case sceneNotForegroundActive = "scene_not_foreground_active"
    case targetAlreadyFirstResponder = "target_already_first_responder"
}

enum InputCapturingResponderRecoveryDecision: Equatable {
    case recover
    case skip(InputCapturingResponderRecoverySkipReason)
}

enum InputCapturingResponderRecoveryPolicy {
    static func target(
        softwareKeyboardVisible: Bool,
        hardwareKeyboardPresent: Bool
    ) -> InputCapturingResponderTarget {
        if softwareKeyboardVisible && !hardwareKeyboardPresent {
            return .softwareKeyboardField
        }
        return .captureView
    }

    static func decision(
        for context: InputCapturingResponderRecoveryContext,
        trigger: InputCapturingResponderRecoveryTrigger
    ) -> InputCapturingResponderRecoveryDecision {
        guard context.hasWindow else { return .skip(.noWindow) }
        guard !context.targetIsFirstResponder else {
            return .skip(.targetAlreadyFirstResponder)
        }
        guard context.isKeyWindow else { return .skip(.windowNotKey) }
        guard isForegroundActiveOrRecoveringFromActivationTransition(
            sceneActivationState: context.sceneActivationState,
            trigger: trigger
        ) else {
            return .skip(.sceneNotForegroundActive)
        }
        return .recover
    }

    static func shouldRetry(
        _ decision: InputCapturingResponderRecoveryDecision,
        attempt: Int
    ) -> Bool {
        guard attempt == 0 else { return false }
        switch decision {
        case .recover,
             .skip(.noWindow),
             .skip(.targetAlreadyFirstResponder):
            return false
        case .skip(.windowNotKey),
             .skip(.sceneNotForegroundActive):
            return true
        }
    }

    private static func isForegroundActiveOrRecoveringFromActivationTransition(
        sceneActivationState: UIScene.ActivationState?,
        trigger: InputCapturingResponderRecoveryTrigger
    ) -> Bool {
        if sceneActivationState == .foregroundActive {
            return true
        }

        switch trigger {
        case .applicationDidBecomeActive,
             .sceneDidActivate,
             .windowDidBecomeKey:
            return true
        case .didMoveToWindow,
             .sceneWillEnterForeground,
             .interaction:
            return false
        }
    }
}

struct InputCapturingResponderRecoveryScheduler {
    var schedule: @MainActor (
        _ delay: Duration,
        _ operation: @escaping @MainActor () -> Void
    ) -> Task<Void, Never>

    static let live = Self { delay, operation in
        Task { @MainActor in
            if delay == .zero {
                await Task.yield()
            } else {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
            }

            guard !Task.isCancelled else { return }
            operation()
        }
    }
}

@MainActor
final class InputCapturingResponderRecoveryController {
    typealias ContextProvider =
        (_ trigger: InputCapturingResponderRecoveryTrigger)
            -> (target: InputCapturingResponderTarget, context: InputCapturingResponderRecoveryContext)
    typealias AttemptHandler = (_ target: InputCapturingResponderTarget) -> Bool
    typealias LogHandler = (
        _ trigger: InputCapturingResponderRecoveryTrigger,
        _ target: InputCapturingResponderTarget,
        _ context: InputCapturingResponderRecoveryContext,
        _ decision: InputCapturingResponderRecoveryDecision,
        _ attempt: Int,
        _ didBecomeFirstResponder: Bool?
    ) -> Void

    var scheduler: InputCapturingResponderRecoveryScheduler

    private let retryDelay: Duration
    private let contextProvider: ContextProvider
    private let attemptHandler: AttemptHandler
    private let logHandler: LogHandler
    private var scheduledRecoveryTask: Task<Void, Never>?

    init(
        scheduler: InputCapturingResponderRecoveryScheduler = .live,
        retryDelay: Duration = .milliseconds(150),
        contextProvider: @escaping ContextProvider,
        attemptHandler: @escaping AttemptHandler,
        logHandler: @escaping LogHandler
    ) {
        self.scheduler = scheduler
        self.retryDelay = retryDelay
        self.contextProvider = contextProvider
        self.attemptHandler = attemptHandler
        self.logHandler = logHandler
    }

    func requestRecovery(_ trigger: InputCapturingResponderRecoveryTrigger) {
        scheduleRecovery(trigger, attempt: 0, delay: .zero)
    }

    func cancel() {
        scheduledRecoveryTask?.cancel()
        scheduledRecoveryTask = nil
    }

    private func scheduleRecovery(
        _ trigger: InputCapturingResponderRecoveryTrigger,
        attempt: Int,
        delay: Duration
    ) {
        scheduledRecoveryTask?.cancel()
        scheduledRecoveryTask = scheduler.schedule(delay) { [weak self] in
            self?.runRecovery(trigger, attempt: attempt)
        }
    }

    private func runRecovery(
        _ trigger: InputCapturingResponderRecoveryTrigger,
        attempt: Int
    ) {
        let snapshot = contextProvider(trigger)
        let decision = InputCapturingResponderRecoveryPolicy.decision(
            for: snapshot.context,
            trigger: trigger
        )

        switch decision {
        case .recover:
            let didBecomeFirstResponder = attemptHandler(snapshot.target)
            logHandler(
                trigger,
                snapshot.target,
                snapshot.context,
                decision,
                attempt,
                didBecomeFirstResponder
            )

            guard !didBecomeFirstResponder, attempt == 0 else {
                scheduledRecoveryTask = nil
                return
            }
            scheduleRecovery(trigger, attempt: attempt + 1, delay: retryDelay)

        case .skip:
            logHandler(
                trigger,
                snapshot.target,
                snapshot.context,
                decision,
                attempt,
                nil
            )

            guard InputCapturingResponderRecoveryPolicy.shouldRetry(
                decision,
                attempt: attempt
            ) else {
                scheduledRecoveryTask = nil
                return
            }
            scheduleRecovery(trigger, attempt: attempt + 1, delay: retryDelay)
        }
    }
}
#endif
