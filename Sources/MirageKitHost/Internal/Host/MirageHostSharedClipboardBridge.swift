//
//  MirageHostSharedClipboardBridge.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/11/26.
//

import AppKit
import Foundation
import MirageKit

private struct HostClipboardSnapshot: Sendable {
    let changeCount: Int
    let text: String?
}

private actor HostClipboardSnapshotReader {
    static let shared = HostClipboardSnapshotReader()

    func snapshot() -> HostClipboardSnapshot {
        let pasteboard = NSPasteboard.general
        let text: String?
        if pasteboard.availableType(from: [.string]) != nil {
            text = pasteboard.string(forType: .string)
        } else {
            text = nil
        }
        return HostClipboardSnapshot(
            changeCount: pasteboard.changeCount,
            text: text
        )
    }
}

@MainActor
final class MirageHostSharedClipboardBridge {
    private let pasteboard: NSPasteboard
    private let pollInterval: Duration
    private let onLocalTextChanged: @MainActor (MirageSharedClipboardLocalSend, Int64) -> Void
    private var clipboardState = MirageSharedClipboardState()
    private var pollTask: Task<Void, Never>?
    private var isActive = false

    init(
        pasteboard: NSPasteboard = .general,
        pollInterval: Duration = .milliseconds(250),
        onLocalTextChanged: @escaping @MainActor (MirageSharedClipboardLocalSend, Int64) -> Void
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
        orderingToken: MirageSharedClipboardOrderingToken,
        sentAtMs: Int64
    ) {
        guard let text = MirageSharedClipboard.validatedText(text) else { return }
        guard clipboardState.shouldApplyRemoteText(orderingToken: orderingToken) else { return }

        _ = pasteboard.prepareForNewContents(with: [.currentHostOnly])
        pasteboard.setString(text, forType: .string)
        clipboardState.recordRemoteWrite(
            text: text,
            changeCount: pasteboard.changeCount,
            orderingToken: orderingToken
        )
    }

    private func activate() {
        clipboardState.activate(changeCount: pasteboard.changeCount)
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                if Task.isCancelled { return }
                let snapshot = await HostClipboardSnapshotReader.shared.snapshot()
                if Task.isCancelled { return }
                await consumePolledSnapshot(snapshot)
            }
        }
    }

    private func deactivate() {
        pollTask?.cancel()
        pollTask = nil
        clipboardState.deactivate()
    }

    private func consumePolledSnapshot(_ snapshot: HostClipboardSnapshot) {
        guard snapshot.changeCount != clipboardState.lastObservedChangeCount else { return }
        completePollPasteboard(text: snapshot.text, changeCount: snapshot.changeCount)
    }

    private func completePollPasteboard(text: String?, changeCount: Int) {
        guard isActive else { return }
        let sentAtMs = MirageSharedClipboard.currentTimestampMs()
        switch clipboardState.observeLocalText(text, changeCount: changeCount) {
        case .ignore:
            break
        case let .send(localSend):
            onLocalTextChanged(localSend, sentAtMs)
        }
    }
}
