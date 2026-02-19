//
//  LatencyModeTypingClassifierTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/13/26.
//
//  Coverage for typing burst key classification.
//

@testable import MirageKit
import Testing

@Suite("Typing Burst Classifier")
struct LatencyModeTypingClassifierTests {
    @Test("Plain typing key down triggers burst classifier")
    func plainTypingKeyDownTriggersClassifier() {
        let event = MirageInputEvent.keyDown(
            MirageKeyEvent(
                keyCode: 0x00,
                characters: "a",
                charactersIgnoringModifiers: "a",
                modifiers: []
            )
        )
        #expect(MirageTypingBurstClassifier.shouldTrigger(for: event))
    }

    @Test("Editing navigation key down triggers burst classifier")
    func editingKeyDownTriggersClassifier() {
        let event = MirageInputEvent.keyDown(
            MirageKeyEvent(
                keyCode: 0x7B,
                characters: nil,
                charactersIgnoringModifiers: nil,
                modifiers: []
            )
        )
        #expect(MirageTypingBurstClassifier.shouldTrigger(for: event))
    }

    @Test("Shortcut modifiers suppress burst classifier")
    func shortcutModifiersSuppressClassifier() {
        let commandEvent = MirageInputEvent.keyDown(
            MirageKeyEvent(
                keyCode: 0x01,
                characters: "s",
                charactersIgnoringModifiers: "s",
                modifiers: [.command]
            )
        )
        let optionEvent = MirageInputEvent.keyDown(
            MirageKeyEvent(
                keyCode: 0x2E,
                characters: "m",
                charactersIgnoringModifiers: "m",
                modifiers: [.option]
            )
        )
        let controlEvent = MirageInputEvent.keyDown(
            MirageKeyEvent(
                keyCode: 0x2B,
                characters: "f",
                charactersIgnoringModifiers: "f",
                modifiers: [.control]
            )
        )

        #expect(!MirageTypingBurstClassifier.shouldTrigger(for: commandEvent))
        #expect(!MirageTypingBurstClassifier.shouldTrigger(for: optionEvent))
        #expect(!MirageTypingBurstClassifier.shouldTrigger(for: controlEvent))
    }

    @Test("Non-key-down events do not trigger burst classifier")
    func nonKeyDownEventsDoNotTriggerClassifier() {
        let event = MirageInputEvent.keyUp(
            MirageKeyEvent(
                keyCode: 0x00,
                characters: "a",
                charactersIgnoringModifiers: "a",
                modifiers: []
            )
        )
        #expect(!MirageTypingBurstClassifier.shouldTrigger(for: event))
    }

    @Test("Mouse events do not trigger burst classifier")
    func mouseEventsDoNotTriggerClassifier() {
        let event = MirageInputEvent.mouseMoved(
            MirageMouseEvent(
                location: .zero
            )
        )
        #expect(!MirageTypingBurstClassifier.shouldTrigger(for: event))
    }
}
