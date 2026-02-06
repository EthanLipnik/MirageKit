//
//  MirageHostInputController+Gestures.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Host input controller extensions.
//

import CoreGraphics
import Foundation
import MirageKit

#if os(macOS)
import AppKit
import ApplicationServices

extension MirageHostInputController {
    // MARK: - Gesture Translation (runs on accessibilityQueue)

    /// Threshold for magnify gesture before triggering a zoom keystroke
    private static let magnifyKeyThreshold: CGFloat = 0.08

    func handleMagnifyGesture(_ event: MirageMagnifyEvent, windowFrame _: CGRect) {
        switch event.phase {
        case .began:
            magnifyAccumulator = 0
        case .changed:
            magnifyAccumulator += event.magnification

            // Use CMD++/- keyboard shortcuts for zoom (more universally recognized than CMD+scroll)
            if magnifyAccumulator >= Self.magnifyKeyThreshold {
                // CMD+= (zoom in) - keyCode 0x18 is '='
                injectKeyboardShortcut(keyCode: 0x18, modifiers: .maskCommand)
                magnifyAccumulator = 0
            } else if magnifyAccumulator <= -Self.magnifyKeyThreshold {
                // CMD+- (zoom out) - keyCode 0x1B is '-'
                injectKeyboardShortcut(keyCode: 0x1B, modifiers: .maskCommand)
                magnifyAccumulator = 0
            }
        case .cancelled,
             .ended:
            // Trigger final zoom if accumulated enough
            if magnifyAccumulator >= Self.magnifyKeyThreshold * 0.5 { injectKeyboardShortcut(keyCode: 0x18, modifiers: .maskCommand) } else if magnifyAccumulator <= -Self.magnifyKeyThreshold * 0.5 {
                injectKeyboardShortcut(keyCode: 0x1B, modifiers: .maskCommand)
            }
            magnifyAccumulator = 0
        default:
            break
        }
    }

    /// Inject a keyboard shortcut (key down + key up)
    private func injectKeyboardShortcut(keyCode: CGKeyCode, modifiers: CGEventFlags) {
        // Key down
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) else { return }
        keyDown.flags = modifiers
        postEvent(keyDown)

        // Key up
        guard let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else { return }
        keyUp.flags = modifiers
        postEvent(keyUp)
    }

    func handleRotateGesture(_ event: MirageRotateEvent, windowFrame: CGRect) {
        switch event.phase {
        case .began:
            rotationAccumulator = 0
        case .changed:
            rotationAccumulator += event.rotation

            if abs(rotationAccumulator) >= rotationScrollThreshold {
                let scrollDelta = Int32(rotationAccumulator * 2)
                injectScrollWithModifier(
                    deltaX: scrollDelta,
                    modifier: .maskAlternate,
                    windowFrame: windowFrame
                )
                rotationAccumulator = 0
            }
        case .cancelled,
             .ended:
            if abs(rotationAccumulator) > 0.5 {
                let scrollDelta = Int32(rotationAccumulator * 2)
                injectScrollWithModifier(
                    deltaX: scrollDelta,
                    modifier: .maskAlternate,
                    windowFrame: windowFrame
                )
            }
            rotationAccumulator = 0
        default:
            break
        }
    }

    private func injectScrollWithModifier(
        deltaX: Int32 = 0,
        deltaY: Int32 = 0,
        modifier: CGEventFlags,
        windowFrame: CGRect
    ) {
        let scrollPoint = CGPoint(x: windowFrame.midX, y: windowFrame.midY)

        guard let cgEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: deltaY,
            wheel2: deltaX,
            wheel3: 0
        ) else {
            return
        }

        cgEvent.location = scrollPoint
        cgEvent.flags = modifier
        postEvent(cgEvent)
    }
}

#endif
