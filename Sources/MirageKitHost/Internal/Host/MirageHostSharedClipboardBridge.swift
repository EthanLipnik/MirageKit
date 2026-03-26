//
//  MirageHostSharedClipboardBridge.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/11/26.
//

import AppKit
import Foundation
import MirageKit

@MainActor
final class MirageHostSharedClipboardBridge {
    private let pasteboard: NSPasteboard
    private let pollInterval: Duration
    private let onLocalTextChanged: @MainActor (String, UUID, Int64) -> Void
    private var clipboardState = MirageSharedClipboardState()
    private var pollTask: Task<Void, Never>?
    private var isActive = false

    init(
        pasteboard: NSPasteboard = .general,
        pollInterval: Duration = .milliseconds(250),
        onLocalTextChanged: @escaping @MainActor (String, UUID, Int64) -> Void
    ) {
        self.pasteboard = pasteboard
        self.pollInterval = pollInterval
        self.onLocalTextChanged = onLocalTextChanged
    }

    deinit {
        pollTask?.cancel()
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

        _ = pasteboard.prepareForNewContents(with: [.currentHostOnly])
        pasteboard.setString(text, forType: .string)
        clipboardState.recordRemoteWrite(text: text, changeCount: pasteboard.changeCount)
    }

    private func activate() {
        clipboardState.activate(changeCount: pasteboard.changeCount)
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                if Task.isCancelled { return }
                await pollPasteboard()
            }
        }
    }

    private func deactivate() {
        pollTask?.cancel()
        pollTask = nil
        clipboardState.deactivate()
    }

    private func pollPasteboard() {
        let changeCount = pasteboard.changeCount
        guard changeCount != clipboardState.lastObservedChangeCount else { return }

        Task.detached(priority: .utility) { [weak self] in
            let text = NSPasteboard.general.string(forType: .string)
            await self?.completePollPasteboard(text: text, changeCount: changeCount)
        }
    }

    private func completePollPasteboard(text: String?, changeCount: Int) {
        guard isActive else { return }
        switch clipboardState.observeLocalText(text, changeCount: changeCount) {
        case .ignore:
            break
        case let .send(text):
            onLocalTextChanged(text, UUID(), Int64(Date().timeIntervalSince1970 * 1000))
        }
    }
}
