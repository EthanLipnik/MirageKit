//
//  InputCapturingView+Setup.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

import MirageKit
#if os(iOS) || os(visionOS)
import AVFAudio
import Speech
import UIKit
#if canImport(GameController)
import GameController
#endif

extension InputCapturingView {
    func setup() {
        insetsLayoutMarginsFromSafeArea = false

        // Create scroll physics view to wrap the sample-buffer view
        // This provides native trackpad scrolling physics (momentum, bounce)
        let scrollPhysicsView = ScrollPhysicsCapturingView(frame: .zero)
        self.scrollPhysicsView = scrollPhysicsView
        scrollPhysicsView.translatesAutoresizingMaskIntoConstraints = false

        // Add metal view to the scroll physics view's content view
        sampleBufferView.translatesAutoresizingMaskIntoConstraints = false
        sampleBufferView.ignoresSafeArea = ignoresSafeArea
        scrollPhysicsView.ignoresSafeArea = ignoresSafeArea
        scrollPhysicsView.contentView.addSubview(sampleBufferView)

        // Add scroll physics view to self
        addSubview(scrollPhysicsView)

        NSLayoutConstraint.activate([
            // Scroll physics view fills our bounds
            scrollPhysicsView.topAnchor.constraint(equalTo: topAnchor),
            scrollPhysicsView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollPhysicsView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollPhysicsView.bottomAnchor.constraint(equalTo: bottomAnchor),

            // The sample-buffer view fills the content view
            sampleBufferView.topAnchor.constraint(equalTo: scrollPhysicsView.contentView.topAnchor),
            sampleBufferView.leadingAnchor.constraint(equalTo: scrollPhysicsView.contentView.leadingAnchor),
            sampleBufferView.trailingAnchor.constraint(equalTo: scrollPhysicsView.contentView.trailingAnchor),
            sampleBufferView.bottomAnchor.constraint(equalTo: scrollPhysicsView.contentView.bottomAnchor),
        ])

        // Configure scroll physics callback
        // Scroll events don't have a gesture recognizer with modifierFlags, so use keyboard state only
        scrollPhysicsView.onScroll = { [weak self] deltaX, deltaY, phase, momentumPhase, source in
            guard let self else { return }
            requestResponderRecovery(.interaction)
            syncModifiersForInput()
            let modifiers = keyboardModifiers
            sendModifierSnapshotIfNeeded(modifiers)
            let location = scrollEventLocation(source: source)
            let scrollEvent = makeScrollEvent(
                deltaX: deltaX,
                deltaY: deltaY,
                location: location,
                phase: phase,
                momentumPhase: momentumPhase,
                modifiers: modifiers,
                isPrecise: true
            )
            if let scrollEvent {
                onInputEvent?(.scrollWheel(scrollEvent))
            }
            clearDirectTouchScrollAnchorIfNeeded(
                source: source,
                phase: phase,
                momentumPhase: momentumPhase
            )
        }

        // Configure trackpad rotation callback
        scrollPhysicsView.onRotation = { [weak self] rotation, phase in
            guard let self else { return }
            requestResponderRecovery(.interaction)
            syncModifiersForInput()
            let event = MirageRotateEvent(rotation: rotation, phase: phase)
            onInputEvent?(.rotate(event))
        }
        scrollPhysicsView.configurePencilTouchHandlers(
            began: { [weak self] touches in self?.handlePencilTouchesBegan(touches) },
            moved: { [weak self] touches, event in self?.handlePencilTouchesMoved(touches, event: event) },
            ended: { [weak self] touches in self?.handlePencilTouchesEnded(touches) },
            cancelled: { [weak self] touches in self?.handlePencilTouchesCancelled(touches) }
        )
        scrollPhysicsView.onDirectTouchActivity = { [weak self] in
            self?.onDirectTouchActivity?()
        }
        scrollPhysicsView.onDirectTouchBegan = { [weak self, weak scrollPhysicsView] location in
            guard let self else { return }
            let localLocation = scrollPhysicsView?.convert(location, to: self) ?? location
            handleDirectTouchBegan(at: localLocation)
        }

        // Enable user interaction
        isUserInteractionEnabled = true
        isMultipleTouchEnabled = true

        setupGestureRecognizers()
        setupPencilContactGestureRecognizer()
        setupPointerInteraction()
        setupVirtualCursorView()
        setupLockedCursorView()
        setupPencilInteraction()
        setupSoftwareKeyboardField()
        updateVirtualTrackpadMode()
        updateCursorLockMode()
        setupSceneLifecycleObservers()
    }

    var responderRecoveryTarget: InputCapturingResponderTarget {
        InputCapturingResponderRecoveryPolicy.target(
            softwareKeyboardVisible: softwareKeyboardVisible,
            hardwareKeyboardPresent: hardwareKeyboardPresent
        )
    }

    func responderRecoverySnapshot() -> (
        target: InputCapturingResponderTarget,
        context: InputCapturingResponderRecoveryContext
    ) {
        let target = responderRecoveryTarget
        let targetResponder: UIResponder? = switch target {
        case .captureView:
            self
        case .softwareKeyboardField:
            softwareKeyboardField
        }
        return (
            target: target,
            context: InputCapturingResponderRecoveryContext(
                hasWindow: window != nil,
                isKeyWindow: window?.isKeyWindow == true,
                sceneActivationState: window?.windowScene?.activationState,
                targetIsFirstResponder: targetResponder?.isFirstResponder == true
            )
        )
    }

    func requestResponderRecovery(
        _ trigger: InputCapturingResponderRecoveryTrigger
    ) {
        responderRecoveryController.requestRecovery(trigger)
    }

    func cancelPendingResponderRecovery() {
        responderRecoveryController.cancel()
    }

    func attemptResponderRecovery(
        for target: InputCapturingResponderTarget
    ) -> Bool {
        switch target {
        case .captureView:
            let didBecomeFirstResponder = becomeFirstResponder()
            return didBecomeFirstResponder || isFirstResponder
        case .softwareKeyboardField:
            updateSoftwareKeyboardVisibility(allowDismissalReset: true)
            return softwareKeyboardField?.isFirstResponder == true
        }
    }

    func logResponderRecovery(
        trigger: InputCapturingResponderRecoveryTrigger,
        target: InputCapturingResponderTarget,
        context: InputCapturingResponderRecoveryContext,
        decision: InputCapturingResponderRecoveryDecision,
        attempt: Int,
        didBecomeFirstResponder: Bool?
    ) {
        if case .skip(.targetAlreadyFirstResponder) = decision { return }

        let streamIDText = streamID.map(String.init(describing:)) ?? "unbound"
        let decisionText = switch decision {
        case .recover:
            "recover"
        case let .skip(reason):
            "skip(\(reason.rawValue))"
        }
        let sceneStateText = switch context.sceneActivationState {
        case .foregroundActive:
            "foreground_active"
        case .foregroundInactive:
            "foreground_inactive"
        case .background:
            "background"
        case .unattached:
            "unattached"
        case nil:
            "nil"
        @unknown default:
            "unknown"
        }
        let successText = didBecomeFirstResponder.map(String.init(describing:)) ?? "nil"
        MirageLogger.client(
            "Responder recovery \(decisionText): " +
                "stream=\(streamIDText), " +
                "trigger=\(trigger.rawValue), " +
                "attempt=\(attempt), " +
                "target=\(target.rawValue), " +
                "hasWindow=\(context.hasWindow), " +
                "keyWindow=\(context.isKeyWindow), " +
                "sceneState=\(sceneStateText), " +
                "targetIsFirstResponder=\(context.targetIsFirstResponder), " +
                "success=\(successText)"
        )
    }
}

#endif
