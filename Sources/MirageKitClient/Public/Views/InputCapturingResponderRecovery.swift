//
//  InputCapturingResponderRecovery.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/12/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
#if os(iOS) || os(visionOS)
import Foundation
import UIKit

/// UIResponder endpoint that should own stream input at the current moment.
enum InputCapturingResponderTarget: String {
    case captureView = "capture_view"
    case softwareKeyboardField = "software_keyboard_field"
}

/// Event that asks the stream view to re-evaluate first-responder ownership.
enum InputCapturingResponderRecoveryTrigger: String {
    case didMoveToWindow = "did_move_to_window"
    case applicationDidBecomeActive = "application_did_become_active"
    case sceneDidActivate = "scene_did_activate"
    case sceneWillEnterForeground = "scene_will_enter_foreground"
    case windowDidBecomeKey = "window_did_become_key"
    case viewDidAppear = "view_did_appear"
    case callbacksConfigured = "callbacks_configured"
    case streamIdentityUpdated = "stream_identity_updated"
    case desktopStreamStarted = "desktop_stream_started"
    case desktopTransitionCommitted = "desktop_transition_committed"
    case hardwareKeyboardPresenceChanged = "hardware_keyboard_presence_changed"
    case focusChanged = "focus_changed"
    case interaction = "interaction"
}

/// Window, scene, and responder state used to decide whether recovery is safe.
struct InputCapturingResponderRecoveryContext: Equatable {
    let hasWindow: Bool
    let isKeyWindow: Bool
    let sceneActivationState: UIScene.ActivationState?
    let targetIsFirstResponder: Bool
}

/// Reason responder recovery was deferred or skipped.
enum InputCapturingResponderRecoverySkipReason: String, Equatable {
    case noWindow = "no_window"
    case windowNotKey = "window_not_key"
    case sceneNotForegroundActive = "scene_not_foreground_active"
    case targetAlreadyFirstResponder = "target_already_first_responder"
}

/// Policy result for a responder recovery attempt.
enum InputCapturingResponderRecoveryDecision: Equatable {
    case recover
    case skip(InputCapturingResponderRecoverySkipReason)
}

/// Pure policy for choosing the input responder and deciding whether to recover it.
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
             .desktopStreamStarted,
             .desktopTransitionCommitted,
             .viewDidAppear,
             .windowDidBecomeKey:
            return true
        case .didMoveToWindow,
             .sceneWillEnterForeground,
             .callbacksConfigured,
             .streamIdentityUpdated,
             .hardwareKeyboardPresenceChanged,
             .focusChanged,
             .interaction:
            return false
        }
    }
}

/// Schedules delayed responder recovery attempts on the main actor.
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
/// Coordinates first-responder recovery retries after lifecycle and input events.
final class InputCapturingResponderRecoveryController {
    typealias ContextProvider =
        () -> (target: InputCapturingResponderTarget, context: InputCapturingResponderRecoveryContext)
    typealias AttemptHandler = (_ target: InputCapturingResponderTarget) -> Bool
    typealias NowProvider = () -> CFAbsoluteTime
    typealias LogHandler = (
        _ trigger: InputCapturingResponderRecoveryTrigger,
        _ target: InputCapturingResponderTarget,
        _ context: InputCapturingResponderRecoveryContext,
        _ decision: InputCapturingResponderRecoveryDecision,
        _ attempt: Int,
        _ didBecomeFirstResponder: Bool?
    ) -> Void

    var scheduler: InputCapturingResponderRecoveryScheduler

    private static let interactionThrottleSeconds: CFAbsoluteTime = 0.250

    private let retryDelay: Duration
    private let nowProvider: NowProvider
    private let contextProvider: ContextProvider
    private let attemptHandler: AttemptHandler
    private let logHandler: LogHandler
    private var scheduledRecoveryTask: Task<Void, Never>?
    private var scheduledTrigger: InputCapturingResponderRecoveryTrigger?
    private var lastInteractionRecoveryRequestAt: CFAbsoluteTime = 0

    init(
        scheduler: InputCapturingResponderRecoveryScheduler = .live,
        retryDelay: Duration = .milliseconds(150),
        nowProvider: @escaping NowProvider = CFAbsoluteTimeGetCurrent,
        contextProvider: @escaping ContextProvider,
        attemptHandler: @escaping AttemptHandler,
        logHandler: @escaping LogHandler
    ) {
        self.scheduler = scheduler
        self.retryDelay = retryDelay
        self.nowProvider = nowProvider
        self.contextProvider = contextProvider
        self.attemptHandler = attemptHandler
        self.logHandler = logHandler
    }

    func requestRecovery(_ trigger: InputCapturingResponderRecoveryTrigger) {
        if trigger == .interaction {
            guard shouldScheduleInteractionRecovery() else { return }
        }
        scheduleRecovery(trigger, attempt: 0, delay: .zero)
    }

    func cancel() {
        scheduledRecoveryTask?.cancel()
        scheduledRecoveryTask = nil
        scheduledTrigger = nil
    }

    private func shouldScheduleInteractionRecovery() -> Bool {
        let snapshot = contextProvider()
        guard !snapshot.context.targetIsFirstResponder else {
            return false
        }
        guard scheduledRecoveryTask == nil || scheduledTrigger == .interaction else {
            return false
        }
        let now = nowProvider()
        guard lastInteractionRecoveryRequestAt == 0 ||
              now - lastInteractionRecoveryRequestAt >= Self.interactionThrottleSeconds else {
            return false
        }
        lastInteractionRecoveryRequestAt = now
        return true
    }

    private func scheduleRecovery(
        _ trigger: InputCapturingResponderRecoveryTrigger,
        attempt: Int,
        delay: Duration
    ) {
        if trigger == .interaction,
           scheduledRecoveryTask != nil,
           scheduledTrigger != .interaction {
            return
        }
        scheduledRecoveryTask?.cancel()
        scheduledTrigger = trigger
        scheduledRecoveryTask = scheduler.schedule(delay) { [weak self] in
            self?.runRecovery(trigger, attempt: attempt)
        }
    }

    private func runRecovery(
        _ trigger: InputCapturingResponderRecoveryTrigger,
        attempt: Int
    ) {
        let snapshot = contextProvider()
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
                scheduledTrigger = nil
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
                scheduledTrigger = nil
                return
            }
            scheduleRecovery(trigger, attempt: attempt + 1, delay: retryDelay)
        }
    }
}
#endif
