//
//  MirageClientSharedClipboardBridge.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/11/26.
//

import Foundation
import MirageKit

#if canImport(AppKit)
import AppKit
#endif

#if canImport(UIKit)
import UIKit
import UniformTypeIdentifiers
#endif

@MainActor
final class MirageClientSharedClipboardBridge {
    private let pollInterval: Duration
    private let onLocalTextChanged: @MainActor (String, UUID, Int64) -> Void
    private var clipboardState = MirageSharedClipboardState()
    private var pollTask: Task<Void, Never>?
    private var pasteboardObserver: NSObjectProtocol?
    private var isActive = false

    init(
        pollInterval: Duration = .milliseconds(250),
        onLocalTextChanged: @escaping @MainActor (String, UUID, Int64) -> Void
    ) {
        self.pollInterval = pollInterval
        self.onLocalTextChanged = onLocalTextChanged
    }

    func setActive(_ isActive: Bool) {
        guard self.isActive != isActive else { return }
        self.isActive = isActive
        if isActive {
            activate()
        } else {
            deactivate()
        }
    }

    func applyRemoteText(
        _ text: String,
        changeID _: UUID,
        sentAtMs _: Int64
    ) {
        guard let text = MirageSharedClipboard.validatedText(text) else { return }

        #if os(macOS)
        let pasteboard = NSPasteboard.general
        _ = pasteboard.prepareForNewContents(with: [.currentHostOnly])
        pasteboard.setString(text, forType: .string)
        clipboardState.recordRemoteWrite(text: text, changeCount: pasteboard.changeCount)
        #elseif canImport(UIKit)
        UIPasteboard.general.setItems(
            [[UTType.plainText.identifier: text]],
            options: [.localOnly: true]
        )
        clipboardState.recordRemoteWrite(text: text, changeCount: UIPasteboard.general.changeCount)
        #endif
    }

    private func activate() {
        clipboardState.activate(changeCount: currentChangeCount())
        startObservation()
    }

    private func deactivate() {
        pollTask?.cancel()
        pollTask = nil
        if let pasteboardObserver {
            NotificationCenter.default.removeObserver(pasteboardObserver)
            self.pasteboardObserver = nil
        }
        clipboardState.deactivate()
    }

    private func startObservation() {
        #if os(macOS)
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                if Task.isCancelled { return }
                await observeLocalClipboardIfNeeded()
            }
        }
        #elseif canImport(UIKit)
        pasteboardObserver = NotificationCenter.default.addObserver(
            forName: UIPasteboard.changedNotification,
            object: UIPasteboard.general,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.observeLocalClipboardIfNeeded()
            }
        }
        #endif
    }

    private func observeLocalClipboardIfNeeded() {
        switch clipboardState.observeLocalText(
            currentClipboardText(),
            changeCount: currentChangeCount()
        ) {
        case .ignore:
            break
        case let .send(text):
            onLocalTextChanged(text, UUID(), Int64(Date().timeIntervalSince1970 * 1000))
        }
    }

    private func currentClipboardText() -> String? {
        #if os(macOS)
        NSPasteboard.general.string(forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string
        #else
        nil
        #endif
    }

    private func currentChangeCount() -> Int {
        #if os(macOS)
        NSPasteboard.general.changeCount
        #elseif canImport(UIKit)
        UIPasteboard.general.changeCount
        #else
        0
        #endif
    }
}
