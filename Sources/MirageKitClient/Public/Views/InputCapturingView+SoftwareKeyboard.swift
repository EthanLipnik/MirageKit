//
//  InputCapturingView+SoftwareKeyboard.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/31/26.
//
//  Software keyboard handling for streamed input.
//

import MirageKit
#if os(iOS) || os(visionOS)
import UIKit

extension InputCapturingView {
    func setupSoftwareKeyboardField() {
        let inputView = SoftwareKeyboardInputView()
        inputView.translatesAutoresizingMaskIntoConstraints = false
        inputView.alpha = 0.01
        inputView.isUserInteractionEnabled = false
        inputView.backgroundColor = .clear
        inputView.onInsertText = { [weak self] text in
            self?.handleSoftwareKeyboardInsertText(text)
        }
        inputView.onDeleteBackward = { [weak self] in
            self?.handleSoftwareKeyboardDeleteBackward()
        }
        inputView.onFirstResponderChanged = { [weak self] isFirstResponder in
            self?.handleSoftwareKeyboardResponderChange(isFirstResponder: isFirstResponder)
        }

        let accessoryView = SoftwareKeyboardAccessoryView()
        accessoryView.onModifierToggle = { [weak self] key, isSelected in
            self?.toggleSoftwareModifier(key, isSelected: isSelected)
        }
        accessoryView.onDismissKeyboard = { [weak self] in
            self?.dismissSoftwareKeyboard()
        }
        #if os(visionOS)
        accessoryView.translatesAutoresizingMaskIntoConstraints = false
        accessoryView.isHidden = true
        addSubview(accessoryView)
        NSLayoutConstraint.activate([
            accessoryView.leadingAnchor.constraint(equalTo: leadingAnchor),
            accessoryView.trailingAnchor.constraint(equalTo: trailingAnchor),
            accessoryView.bottomAnchor.constraint(equalTo: bottomAnchor),
            accessoryView.heightAnchor.constraint(equalToConstant: 44),
        ])
        #else
        inputView.keyboardAccessoryView = accessoryView
        #endif

        addSubview(inputView)
        NSLayoutConstraint.activate([
            inputView.leadingAnchor.constraint(equalTo: leadingAnchor),
            inputView.topAnchor.constraint(equalTo: topAnchor),
            inputView.widthAnchor.constraint(equalToConstant: 1),
            inputView.heightAnchor.constraint(equalToConstant: 1),
        ])

        softwareKeyboardField = inputView
        softwareKeyboardAccessoryView = accessoryView
    }

    func updateSoftwareKeyboardVisibility() {
        guard let inputView = softwareKeyboardField else { return }
        let shouldShow = softwareKeyboardVisible && !softwareKeyboardDismissalPending && !hardwareKeyboardPresent
        if shouldShow {
            if !inputView.isFirstResponder {
                inputView.becomeFirstResponder()
            }
            inputView.reloadInputViews()
        } else if inputView.isFirstResponder {
            inputView.resignFirstResponder()
        }
        #if os(visionOS)
        softwareKeyboardAccessoryView?.isHidden = !shouldShow
        #endif
    }

    func clearSoftwareKeyboardState() {
        if softwareKeyboardVisible || isSoftwareKeyboardResponderActive {
            softwareKeyboardDismissalPending = true
        }
        if softwareKeyboardField?.isFirstResponder == true {
            softwareKeyboardField?.resignFirstResponder()
        } else {
            handleSoftwareKeyboardResponderChange(isFirstResponder: false)
        }
    }

    func updateSoftwareModifierButtons() {
        let visualUpdates = softwareKeyboardAccessoryView?.setSelectedModifiers(softwareHeldModifiers) ?? 0
        recordSoftwareModifierSyncResult(visualUpdates: visualUpdates)
    }

    func toggleSoftwareModifier(_ key: SoftwareModifierKey, isSelected: Bool) {
        if isSelected { softwareHeldModifiers.insert(key.modifier) } else {
            softwareHeldModifiers.remove(key.modifier)
        }
        updateSoftwareModifierButtons()
        sendModifierStateIfNeeded(force: true)
    }

    func handleSoftwareKeyboardInsertText(_ text: String) {
        guard !hardwareKeyboardPresent else { return }
        sendModifierStateIfNeeded(force: true)
        let modifiers = keyboardModifiers
        for scalar in text {
            let character = String(scalar)
            if character == "\n" {
                sendSoftwareKeyEvent(
                    keyCode: 0x24,
                    characters: "\n",
                    charactersIgnoringModifiers: "\n",
                    modifiers: modifiers
                )
                continue
            }
            guard let event = softwareKeyEvent(for: character, baseModifiers: modifiers) else { continue }
            sendSoftwareKeyEvent(
                keyCode: event.keyCode,
                characters: event.characters,
                charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                modifiers: event.modifiers
            )
        }
    }

    func handleSoftwareKeyboardDeleteBackward() {
        guard !hardwareKeyboardPresent else { return }
        sendModifierStateIfNeeded(force: true)
        let modifiers = keyboardModifiers
        sendSoftwareKeyEvent(keyCode: 0x33, characters: nil, charactersIgnoringModifiers: nil, modifiers: modifiers)
    }

    func dismissSoftwareKeyboard() {
        softwareKeyboardDismissalPending = true
        if softwareKeyboardField?.isFirstResponder == true {
            softwareKeyboardField?.resignFirstResponder()
        } else {
            handleSoftwareKeyboardResponderChange(isFirstResponder: false)
        }
    }

    func handleSoftwareKeyboardResponderChange(isFirstResponder: Bool) {
        guard isSoftwareKeyboardResponderActive != isFirstResponder else { return }
        isSoftwareKeyboardResponderActive = isFirstResponder
        if isFirstResponder {
            softwareKeyboardDismissalPending = false
            notifySoftwareKeyboardVisibilityChanged(true)
            return
        }

        if softwareKeyboardVisible {
            softwareKeyboardDismissalPending = true
        }
        softwareHeldModifiers = []
        updateSoftwareModifierButtons()
        sendModifierStateIfNeeded(force: true)
        refreshCursorUpdates(force: true)
        notifySoftwareKeyboardVisibilityChanged(false)
    }

    func notifySoftwareKeyboardVisibilityChanged(_ isVisible: Bool) {
        guard isSoftwareKeyboardShown != isVisible else { return }
        isSoftwareKeyboardShown = isVisible
        onSoftwareKeyboardVisibilityChanged?(isVisible)
    }

    func sendSoftwareKeyEvent(
        keyCode: UInt16,
        characters: String?,
        charactersIgnoringModifiers: String?,
        modifiers: MirageModifierFlags
    ) {
        hideCursorForTypingUntilPointerMovement()
        let keyDown = MirageKeyEvent(
            keyCode: keyCode,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            modifiers: modifiers
        )
        onInputEvent?(.keyDown(keyDown))

        let keyUp = MirageKeyEvent(
            keyCode: keyCode,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            modifiers: modifiers
        )
        onInputEvent?(.keyUp(keyUp))
    }

    func softwareKeyEvent(for character: String, baseModifiers: MirageModifierFlags) -> SoftwareKeyEvent? {
        MirageClientKeyEventBuilder.softwareKeyEvent(
            for: character,
            baseModifiers: baseModifiers
        )
    }
}

struct SoftwareModifierKey: Hashable {
    let title: String
    let modifier: MirageModifierFlags
}

final class SoftwareKeyboardInputView: UIView, UIKeyInput, UITextInputTraits {
    var onInsertText: ((String) -> Void)?
    var onDeleteBackward: (() -> Void)?
    var onFirstResponderChanged: ((Bool) -> Void)?
    var keyboardAccessoryView: UIView?

    var autocapitalizationType: UITextAutocapitalizationType = .none
    var autocorrectionType: UITextAutocorrectionType = .no
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardType: UIKeyboardType = .asciiCapable
    var keyboardAppearance: UIKeyboardAppearance = .default
    var returnKeyType: UIReturnKeyType = .default
    var enablesReturnKeyAutomatically = false
    var isSecureTextEntry = false
    var textContentType: UITextContentType! = .none
    var passwordRules: UITextInputPasswordRules?

    var hasText: Bool { true }

    override var canBecomeFirstResponder: Bool { true }

    #if !os(visionOS)
    override var inputAccessoryView: UIView? { keyboardAccessoryView }
    #endif

    override func becomeFirstResponder() -> Bool {
        let didBecomeFirstResponder = super.becomeFirstResponder()
        if didBecomeFirstResponder {
            onFirstResponderChanged?(true)
        }
        return didBecomeFirstResponder
    }

    override func resignFirstResponder() -> Bool {
        let didResignFirstResponder = super.resignFirstResponder()
        if didResignFirstResponder {
            onFirstResponderChanged?(false)
        }
        return didResignFirstResponder
    }

    func insertText(_ text: String) {
        onInsertText?(text)
    }

    func deleteBackward() {
        onDeleteBackward?()
    }
}

final class SoftwareKeyboardAccessoryView: UIView {
    var onModifierToggle: ((SoftwareModifierKey, Bool) -> Void)?
    var onDismissKeyboard: (() -> Void)?

    private let stackView = UIStackView()
    private let spacerView = UIView()
    private let doneButton = UIButton(type: .system)
    private let keys: [SoftwareModifierKey] = [
        SoftwareModifierKey(title: "Cmd", modifier: .command),
        SoftwareModifierKey(title: "Option", modifier: .option),
        SoftwareModifierKey(title: "Control", modifier: .control),
    ]
    private var buttons: [MirageModifierFlags: UIButton] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: 44) }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: 44)
    }

    @discardableResult
    func setSelectedModifiers(_ modifiers: MirageModifierFlags) -> Int {
        var updatedButtonCount = 0
        for (flag, button) in buttons {
            let isSelected = modifiers.contains(flag)
            guard button.isSelected != isSelected else { continue }
            updateButton(button, isSelected: isSelected)
            updatedButtonCount += 1
        }
        return updatedButtonCount
    }

    private func setup() {
        frame = CGRect(origin: .zero, size: CGSize(width: 0, height: 44))
        autoresizingMask = [.flexibleWidth]
        backgroundColor = .clear
        isOpaque = false

        stackView.axis = .horizontal
        stackView.alignment = .center
        stackView.spacing = 8
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.isLayoutMarginsRelativeArrangement = true
        stackView.layoutMargins = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)

        for key in keys {
            let button = UIButton(type: .system)
            button.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
            button.configuration = buttonConfiguration(title: key.title, isSelected: false)
            button.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                let isSelected = !(button.isSelected)
                button.isSelected = isSelected
                updateButton(button, isSelected: isSelected)
                onModifierToggle?(key, isSelected)
            }, for: .touchUpInside)
            updateButton(button, isSelected: false)
            buttons[key.modifier] = button
            stackView.addArrangedSubview(button)
        }

        spacerView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacerView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stackView.addArrangedSubview(spacerView)

        doneButton.configuration = buttonConfiguration(title: "Done", isSelected: false)
        doneButton.addAction(UIAction { [weak self] _ in
            self?.onDismissKeyboard?()
        }, for: .touchUpInside)
        stackView.addArrangedSubview(doneButton)

        addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func updateButton(_ button: UIButton, isSelected: Bool) {
        button.isSelected = isSelected
        button.configuration = buttonConfiguration(
            title: button.configuration?.title ?? button.titleLabel?.text,
            isSelected: isSelected
        )
    }

    private func buttonConfiguration(title: String?, isSelected: Bool) -> UIButton.Configuration {
        #if os(visionOS)
        var configuration = isSelected ? UIButton.Configuration.borderedProminent() : UIButton.Configuration.bordered()
        #else
        var configuration: UIButton.Configuration
        if #available(iOS 26.0, *) {
            configuration = isSelected ? .prominentGlass() : .glass()
        } else {
            configuration = isSelected ? .borderedProminent() : .bordered()
        }
        #endif
        configuration.title = title
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var updated = attributes
            updated.font = .systemFont(ofSize: 15, weight: .semibold)
            return updated
        }
        return configuration
    }
}
#endif
