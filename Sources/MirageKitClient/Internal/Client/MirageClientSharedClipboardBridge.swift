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
#endif

private struct ClientClipboardSnapshot: Sendable {
    let changeCount: Int
    let text: String?
}

private actor ClientClipboardSnapshotReader {
    static let shared = ClientClipboardSnapshotReader()

    func snapshot() -> ClientClipboardSnapshot {
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        let text: String? = if pasteboard.availableType(from: [.string]) != nil {
            pasteboard.string(forType: .string)
        } else {
            nil
        }
        return ClientClipboardSnapshot(changeCount: pasteboard.changeCount, text: text)
        #elseif canImport(UIKit)
        let pasteboard = UIPasteboard.general
        let text: String? = if pasteboard.hasStrings {
            pasteboard.string
        } else {
            nil
        }
        return ClientClipboardSnapshot(changeCount: pasteboard.changeCount, text: text)
        #else
        return ClientClipboardSnapshot(changeCount: 0, text: nil)
        #endif
    }

    func changeCount() -> Int {
        #if os(macOS)
        NSPasteboard.general.changeCount
        #elseif canImport(UIKit)
        UIPasteboard.general.changeCount
        #else
        0
        #endif
    }

    func applyText(_ text: String) -> Int {
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        _ = pasteboard.prepareForNewContents(with: [.currentHostOnly])
        pasteboard.setString(text, forType: .string)
        return pasteboard.changeCount
        #elseif canImport(UIKit)
        UIPasteboard.general.string = text
        return UIPasteboard.general.changeCount
        #else
        return 0
        #endif
    }
}

@MainActor
final class MirageClientSharedClipboardBridge {
    private var clipboardState = MirageSharedClipboardState()
    private var isActive = false

    init() {}

    func setActive(_ isActive: Bool) async {
        let wasActive = self.isActive

        if isActive == wasActive { return }

        self.isActive = isActive
        if isActive {
            await activate()
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
            MirageLogger.client("Ignoring invalid shared clipboard text from host")
            return
        }
        guard clipboardState.shouldApplyRemoteText(orderingToken: orderingToken) else {
            MirageLogger.client("Ignoring stale shared clipboard update from host")
            return
        }

        let changeCount = await ClientClipboardSnapshotReader.shared.applyText(text)
        clipboardState.recordRemoteWrite(
            text: text,
            changeCount: changeCount,
            orderingToken: orderingToken
        )
        MirageLogger.client(
            "Applied shared clipboard update from host: bytes=\(text.utf8.count), sentAtMs=\(sentAtMs)"
        )
    }

    func prepareCurrentClipboardManualSend()
        async -> (localSend: MirageSharedClipboardLocalSend, sentAtMs: Int64)? {
        let snapshot = await ClientClipboardSnapshotReader.shared.snapshot()
        guard let localSend = clipboardState.prepareManualLocalSend(
            currentText: snapshot.text,
            changeCount: snapshot.changeCount
        ) else {
            MirageLogger.client("Shared clipboard manual sync skipped: no valid local text")
            return nil
        }

        let sentAtMs = MirageSharedClipboard.currentTimestampMs()
        return (localSend, sentAtMs)
    }

    private func activate() async {
        let changeCount = await ClientClipboardSnapshotReader.shared.changeCount()
        clipboardState.activate(changeCount: changeCount)
    }

    private func deactivate() {
        clipboardState.deactivate()
    }
}
