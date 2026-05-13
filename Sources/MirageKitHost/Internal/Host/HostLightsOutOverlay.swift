//
//  HostLightsOutOverlay.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//
//  Overlay window support for host Lights Out mode.
//

import AppKit
import CoreGraphics

#if os(macOS)
/// Original display gamma tables captured so Lights Out dimming can be reversed exactly.
struct HostLightsOutGammaSnapshot {
    /// Red channel transfer table.
    let red: [CGGammaValue]

    /// Green channel transfer table.
    let green: [CGGammaValue]

    /// Blue channel transfer table.
    let blue: [CGGammaValue]

    /// Number of valid transfer-table samples.
    let sampleCount: UInt32
}

/// Full-screen overlay window and recovery message for one display during Lights Out mode.
@MainActor
final class HostLightsOutOverlay {
    /// Non-capturable black overlay window.
    let window: NSWindow

    private let messageLabel: NSTextField

    /// Creates and shows a black, non-capturable overlay over `frame`.
    init(frame: CGRect, message: String) {
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.animationBehavior = .none
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.level = .screenSaver
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.sharingType = .none

        let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor

        let label = NSTextField(labelWithString: message)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = .white
        label.alignment = .center
        label.font = .systemFont(ofSize: 28, weight: .semibold)
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byWordWrapping
        label.isHidden = true

        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        window.contentView = view
        window.orderFrontRegardless()

        self.window = window
        messageLabel = label
    }

    /// Moves the overlay to match a changed display frame.
    func updateFrame(_ frame: CGRect) {
        window.setFrame(frame, display: true, animate: false)
        if let view = window.contentView {
            view.frame = CGRect(origin: .zero, size: frame.size)
        }
    }

    /// Shows or hides the local recovery shortcut message.
    func setMessageVisible(_ visible: Bool) {
        messageLabel.isHidden = !visible
    }

    /// Replaces the shortcut message shown during local interaction.
    func setMessage(_ message: String) {
        messageLabel.stringValue = message
    }

    /// Removes the overlay window and releases its view hierarchy.
    func close() {
        window.orderOut(nil)
        window.contentView = nil
    }
}

#endif
