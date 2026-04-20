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

    func changeCount() -> Int {
        NSPasteboard.general.changeCount
    }

    func applyText(_ text: String) -> Int {
        let pasteboard = NSPasteboard.general
        _ = pasteboard.prepareForNewContents(with: [.currentHostOnly])
        pasteboard.setString(text, forType: .string)
        return pasteboard.changeCount
    }
}

@MainActor
final class MirageHostSharedClipboardBridge {
    private let pollInterval: Duration
    private let onLocalTextChanged: @MainActor (MirageSharedClipboardLocalSend, Int64) -> Void
    private var clipboardState = MirageSharedClipboardState()
    private var pollTask: Task<Void, Never>?
    private var isActive = false

    init(
        pollInterval: Duration = .milliseconds(250),
        onLocalTextChanged: @escaping @MainActor (MirageSharedClipboardLocalSend, Int64) -> Void
    ) {
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
    ) async {
        guard let text = MirageSharedClipboard.validatedText(text) else {
            MirageLogger.host("Ignoring invalid shared clipboard text from client")
            return
        }
        guard clipboardState.shouldApplyRemoteText(orderingToken: orderingToken) else {
            MirageLogger.host("Ignoring stale shared clipboard update from client")
            return
        }

        let changeCount = await HostClipboardSnapshotReader.shared.applyText(text)
        clipboardState.recordRemoteWrite(
            text: text,
            changeCount: changeCount,
            orderingToken: orderingToken
        )
        MirageLogger.host(
            "Applied shared clipboard update from client: bytes=\(text.utf8.count), sentAtMs=\(sentAtMs)"
        )
    }

    private func activate() {
        pollTask = Task { [weak self] in
            guard let self else { return }
            let initialCount = await HostClipboardSnapshotReader.shared.changeCount()
            clipboardState.activate(changeCount: initialCount)
            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                if Task.isCancelled { return }
                let snapshot = await HostClipboardSnapshotReader.shared.snapshot()
                if Task.isCancelled { return }
                consumePolledSnapshot(snapshot)
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
            MirageLogger.host(
                "Observed host shared clipboard change: bytes=\(localSend.text.utf8.count)"
            )
            onLocalTextChanged(localSend, sentAtMs)
        }
    }
}
