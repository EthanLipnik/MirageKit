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
    private let pollInterval: Duration
    private let onLocalTextChanged: @MainActor (MirageSharedClipboardLocalSend, Int64) -> Void
    private var clipboardState = MirageSharedClipboardState()
    private var pollTask: Task<Void, Never>?
    private var pasteboardObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?
    private var isActive = false
    private var autoSync = true

    init(
        pollInterval: Duration = .milliseconds(250),
        onLocalTextChanged: @escaping @MainActor (MirageSharedClipboardLocalSend, Int64) -> Void
    ) {
        self.pollInterval = pollInterval
        self.onLocalTextChanged = onLocalTextChanged
    }

    func setActive(_ isActive: Bool, autoSync: Bool = true) async {
        let wasActive = self.isActive
        let wasAutoSync = self.autoSync
        self.autoSync = autoSync

        if isActive == wasActive, autoSync == wasAutoSync { return }

        self.isActive = isActive
        if isActive {
            if wasActive {
                // Mode changed while active — restart observation.
                deactivate()
            }
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
        guard let text = MirageSharedClipboard.validatedText(text) else { return }
        guard clipboardState.shouldApplyRemoteText(orderingToken: orderingToken) else { return }

        let changeCount = await ClientClipboardSnapshotReader.shared.applyText(text)
        clipboardState.recordRemoteWrite(
            text: text,
            changeCount: changeCount,
            orderingToken: orderingToken
        )
    }

    func syncCurrentClipboardToRemote() async {
        let snapshot = await ClientClipboardSnapshotReader.shared.snapshot()
        guard let localSend = clipboardState.prepareManualLocalSend(
            currentText: snapshot.text,
            changeCount: snapshot.changeCount
        ) else {
            return
        }

        let sentAtMs = MirageSharedClipboard.currentTimestampMs()
        onLocalTextChanged(localSend, sentAtMs)
    }

    private func activate() async {
        let changeCount = await ClientClipboardSnapshotReader.shared.changeCount()
        clipboardState.activate(changeCount: changeCount)
        // No initial clipboard send — clipboard sharing only applies to changes
        // that happen while a stream is active, not pre-existing clipboard content.
        startObservation()
    }

    private func deactivate() {
        pollTask?.cancel()
        pollTask = nil
        if let pasteboardObserver {
            NotificationCenter.default.removeObserver(pasteboardObserver)
            self.pasteboardObserver = nil
        }
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
            self.foregroundObserver = nil
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
                let snapshot = await ClientClipboardSnapshotReader.shared.snapshot()
                if Task.isCancelled { return }
                consumePolledSnapshot(snapshot)
            }
        }
        #elseif canImport(UIKit)
        pasteboardObserver = NotificationCenter.default.addObserver(
            forName: UIPasteboard.changedNotification,
            object: UIPasteboard.general,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.observeOrTrackClipboard()
            }
        }

        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.observeOrTrackClipboard()
            }
        }

        #endif
    }

    private func observeOrTrackClipboard() async {
        if autoSync {
            let snapshot = await ClientClipboardSnapshotReader.shared.snapshot()
            guard snapshot.changeCount != clipboardState.lastObservedChangeCount else { return }
            completeClipboardObservation(text: snapshot.text, changeCount: snapshot.changeCount)
        } else {
            let changeCount = await ClientClipboardSnapshotReader.shared.changeCount()
            clipboardState.recordObservedLocalChangeCount(changeCount)
        }
    }

    private func consumePolledSnapshot(_ snapshot: ClientClipboardSnapshot) {
        guard snapshot.changeCount != clipboardState.lastObservedChangeCount else { return }
        completeClipboardObservation(text: snapshot.text, changeCount: snapshot.changeCount)
    }

    @MainActor
    private func completeClipboardObservation(text: String?, changeCount: Int) {
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
