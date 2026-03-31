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
        let textField = SoftwareKeyboardTextField()
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.isHidden = false
        textField.alpha = 0
        textField.isUserInteractionEnabled = true
        textField.backgroundColor = .clear
        textField.textColor = .clear
        textField.tintColor = .clear
        textField.delegate = self
        textField.autocorrectionType = .no
        textField.autocapitalizationType = .none
        textField.spellCheckingType = .no
        textField.smartDashesType = .no
        textField.smartQuotesType = .no
        textField.keyboardType = .asciiCapable
        textField.returnKeyType = .default
        textField.textContentType = .none
        textField.onDeleteBackward = { [weak self] in
            self?.handleSoftwareKeyboardDeleteBackward()
        }

        let accessoryView = SoftwareKeyboardAccessoryView()
        accessoryView.onModifierToggle = { [weak self] key, isSelected in
            self?.toggleSoftwareModifier(key, isSelected: isSelected)
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
        textField.inputAccessoryView = accessoryView
        #endif

        addSubview(textField)
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: leadingAnchor),
            textField.topAnchor.constraint(equalTo: topAnchor),
            textField.widthAnchor.constraint(equalToConstant: 1),
            textField.heightAnchor.constraint(equalToConstant: 1),
        ])

        softwareKeyboardField = textField
        softwareKeyboardAccessoryView = accessoryView
    }

    func updateSoftwareKeyboardVisibility() {
        guard let textField = softwareKeyboardField else { return }
        if softwareKeyboardVisible, !hardwareKeyboardPresent {
            textField.becomeFirstResponder()
            textField.reloadInputViews()
        } else {
            textField.resignFirstResponder()
        }
        #if os(visionOS)
        softwareKeyboardAccessoryView?.isHidden = !(softwareKeyboardVisible && !hardwareKeyboardPresent)
        #endif
    }

    func clearSoftwareKeyboardState() {
        softwareKeyboardVisible = false
        softwareKeyboardField?.resignFirstResponder()
        softwareHeldModifiers = []
        updateSoftwareModifierButtons()
        sendModifierStateIfNeeded(force: true)
        if isSoftwareKeyboardShown {
            isSoftwareKeyboardShown = false
            onSoftwareKeyboardVisibilityChanged?(false)
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

extension InputCapturingView: UITextFieldDelegate {
    public func textField(
        _ textField: UITextField,
        shouldChangeCharactersIn _: NSRange,
        replacementString string: String
    )
    -> Bool {
        guard textField === softwareKeyboardField else { return true }
        if !string.isEmpty { handleSoftwareKeyboardInsertText(string) }
        return false
    }

    public func textFieldDidBeginEditing(_: UITextField) {
        isSoftwareKeyboardShown = true
        if !softwareKeyboardVisible { softwareKeyboardVisible = true }
        onSoftwareKeyboardVisibilityChanged?(true)
    }

    public func textFieldDidEndEditing(_: UITextField) {
        isSoftwareKeyboardShown = false
        if softwareKeyboardVisible { softwareKeyboardVisible = false }
        softwareHeldModifiers = []
        updateSoftwareModifierButtons()
        sendModifierStateIfNeeded(force: true)
        refreshCursorUpdates(force: true)
        onSoftwareKeyboardVisibilityChanged?(false)
    }
}

struct SoftwareModifierKey: Hashable {
    let title: String
    let modifier: MirageModifierFlags
}

final class SoftwareKeyboardTextField: UITextField {
    var onDeleteBackward: (() -> Void)?

    override func deleteBackward() {
        onDeleteBackward?()
    }

    override var canBecomeFirstResponder: Bool { true }
}

final class SoftwareKeyboardAccessoryView: UIView {
    var onModifierToggle: ((SoftwareModifierKey, Bool) -> Void)?

    private let stackView = UIStackView()
    private let spacerView = UIView()
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
            #if os(visionOS)
            var configuration = UIButton.Configuration.bordered()
            #else
            var configuration: UIButton.Configuration
            if #available(iOS 26.0, *) {
                configuration = .glass()
            } else {
                configuration = .bordered()
            }
            #endif
            configuration.title = key.title
            configuration.cornerStyle = .capsule
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
            button.configuration = configuration
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
        configuration.title = button.configuration?.title ?? button.titleLabel?.text
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var updated = attributes
            updated.font = .systemFont(ofSize: 15, weight: .semibold)
            return updated
        }
        button.configuration = configuration
    }
}
#endif
