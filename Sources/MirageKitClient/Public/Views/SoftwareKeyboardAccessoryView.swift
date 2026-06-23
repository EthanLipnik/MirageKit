//
//  SoftwareKeyboardAccessoryView.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/13/26.
//

import MirageKit

#if os(iOS) || os(visionOS)
import UIKit

/// Modifier toolbar shown with the software keyboard for host-side shortcut input.
final class SoftwareKeyboardAccessoryView: UIView {
    var onModifierTap: ((SoftwareModifierKey, Int) -> Void)?
    var onModifierHold: ((SoftwareModifierKey) -> Void)?
    var onDismissKeyboard: (() -> Void)?

    private static let accessoryHeight: CGFloat = 52
    private static let buttonMinimumHeight: CGFloat = 36

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

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: Self.accessoryHeight) }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: Self.accessoryHeight)
    }

    /// Applies the current held-modifier state and returns the number of buttons that changed.
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
        frame = CGRect(origin: .zero, size: CGSize(width: 0, height: Self.accessoryHeight))
        autoresizingMask = [.flexibleWidth]
        backgroundColor = .clear
        isOpaque = false

        stackView.axis = .horizontal
        stackView.alignment = .center
        stackView.spacing = 8
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.isLayoutMarginsRelativeArrangement = true
        stackView.layoutMargins = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)

        for key in keys {
            let button = UIButton(type: .system)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
            button.configuration = buttonConfiguration(title: key.title, isSelected: false)
            button.addTarget(self, action: #selector(handleModifierButtonTap(_:for:)), for: .touchUpInside)
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.buttonMinimumHeight).isActive = true
            button.setContentCompressionResistancePriority(.required, for: .vertical)
            button.setContentHuggingPriority(.required, for: .vertical)

            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleModifierButtonLongPress(_:)))
            longPress.minimumPressDuration = 0.35
            longPress.cancelsTouchesInView = true
            button.addGestureRecognizer(longPress)

            updateButton(button, isSelected: false)
            buttons[key.modifier] = button
            stackView.addArrangedSubview(button)
        }

        spacerView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacerView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stackView.addArrangedSubview(spacerView)

        doneButton.configuration = buttonConfiguration(title: "Done", isSelected: false)
        doneButton.translatesAutoresizingMaskIntoConstraints = false
        doneButton.addAction(UIAction { [weak self] _ in
            self?.onDismissKeyboard?()
        }, for: .touchUpInside)
        doneButton.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.buttonMinimumHeight).isActive = true
        doneButton.setContentCompressionResistancePriority(.required, for: .vertical)
        doneButton.setContentHuggingPriority(.required, for: .vertical)
        stackView.addArrangedSubview(doneButton)

        addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @objc
    private func handleModifierButtonTap(_ sender: UIButton, for event: UIEvent) {
        guard let key = key(for: sender) else { return }
        let tapCount = event.allTouches?.map(\.tapCount).max() ?? 1
        onModifierTap?(key, tapCount)
    }

    @objc
    private func handleModifierButtonLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began,
              let button = recognizer.view as? UIButton,
              let key = key(for: button) else {
            return
        }
        onModifierHold?(key)
    }

    private func key(for button: UIButton) -> SoftwareModifierKey? {
        keys.first { key in
            buttons[key.modifier] === button
        }
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
        var configuration = isSelected ? UIButton.Configuration.prominentGlass() : UIButton.Configuration.glass()
        #endif
        configuration.title = title
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 10, bottom: 7, trailing: 10)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var updated = attributes
            updated.font = .systemFont(ofSize: 15, weight: .semibold)
            return updated
        }
        return configuration
    }
}
#endif
