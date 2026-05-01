//
//  MirageHostSharedClipboardBridge.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/11/26.
//

import AppKit
import Foundation
import MirageKit

private actor HostClipboardSnapshotReader {
    static let shared = HostClipboardSnapshotReader()

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
    private var clipboardState = MirageSharedClipboardState()
    private var isActive = false

    init() {}

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
        Task { [weak self] in
            guard let self else { return }
            let initialCount = await HostClipboardSnapshotReader.shared.changeCount()
            guard self.isActive else { return }
            clipboardState.activate(changeCount: initialCount)
        }
    }

    private func deactivate() {
        clipboardState.deactivate()
    }
}
