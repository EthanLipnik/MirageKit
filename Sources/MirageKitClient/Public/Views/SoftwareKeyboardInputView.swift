//
//  SoftwareKeyboardInputView.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/13/26.
//

#if os(iOS) || os(visionOS)
import UIKit

/// Hidden text-input responder that exposes the system software keyboard to streamed input.
final class SoftwareKeyboardInputView: UITextField {
    var onInsertText: ((String) -> Void)?
    var onDeleteBackward: (() -> Void)?
    var onPaste: (() -> Void)?
    var onFirstResponderChanged: ((Bool) -> Void)?
    var onAttachmentChanged: ((Bool) -> Void)?

    /// Reports that delete/backspace should remain enabled for forwarded input.
    override var hasText: Bool { true }

    override var canBecomeFirstResponder: Bool { true }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

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

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onAttachmentChanged?(window != nil)
    }

    override func insertText(_ text: String) {
        onInsertText?(text)
    }

    override func deleteBackward() {
        onDeleteBackward?()
    }

    override func paste(_: Any?) {
        onPaste?()
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) {
            return onPaste != nil
        }
        return super.canPerformAction(action, withSender: sender)
    }

    private func configure() {
        isOpaque = false
        borderStyle = .none
        backgroundColor = .clear
        textColor = .clear
        tintColor = .clear
        autocapitalizationType = .none
        autocorrectionType = .no
        spellCheckingType = .no
        smartDashesType = .no
        smartQuotesType = .no
        smartInsertDeleteType = .no
        keyboardType = .asciiCapable
        keyboardAppearance = .default
        returnKeyType = .default
        enablesReturnKeyAutomatically = false
        isSecureTextEntry = false
        textContentType = nil
        passwordRules = nil
        #if !os(visionOS)
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []
        #endif
    }
}
#endif
