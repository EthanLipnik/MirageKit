//
//  SoftwareKeyboardInputView.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/13/26.
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
import UIKit

/// Hidden text-input responder that exposes the system software keyboard to streamed input.
final class SoftwareKeyboardInputView: UIView, UIKeyInput {
    var onInsertText: ((String) -> Void)?
    var onDeleteBackward: (() -> Void)?
    var onPaste: (() -> Void)?
    var onFirstResponderChanged: ((Bool) -> Void)?
    var onAttachmentChanged: ((Bool) -> Void)?
    var softwareInputAccessoryView: UIView?

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
    var textContentType: UITextContentType?
    var passwordRules: UITextInputPasswordRules?

    /// Reports that delete/backspace should remain enabled for forwarded input.
    var hasText: Bool { true }

    override var canBecomeFirstResponder: Bool { true }

    #if !os(visionOS)
    override var inputAccessoryView: UIView? {
        softwareInputAccessoryView
    }
    #endif

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

    func insertText(_ text: String) {
        onInsertText?(text)
    }

    func deleteBackward() {
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
        tintColor = .clear
    }
}
#endif
