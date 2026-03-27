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

@MainActor
final class MirageClientSharedClipboardBridge {
    private let pollInterval: Duration
    private let onLocalTextChanged: @MainActor (String, UUID, Int64) -> Void
    private var clipboardState = MirageSharedClipboardState()
    private var pollTask: Task<Void, Never>?
    private var pasteboardObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?
    private var isActive = false
    private var autoSync = true

    init(
        pollInterval: Duration = .milliseconds(250),
        onLocalTextChanged: @escaping @MainActor (String, UUID, Int64) -> Void
    ) {
        self.pollInterval = pollInterval
        self.onLocalTextChanged = onLocalTextChanged
    }

    func setActive(_ isActive: Bool, autoSync: Bool = true) {
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
            activate()
        } else {
            deactivate()
        }
    }

    func applyRemoteText(
        _ text: String,
        changeID _: UUID,
        sentAtMs: Int64
    ) {
        guard let text = MirageSharedClipboard.validatedText(text) else { return }
        guard clipboardState.shouldApplyRemoteText(sentAtMs: sentAtMs) else { return }

        #if os(macOS)
        let pasteboard = NSPasteboard.general
        _ = pasteboard.prepareForNewContents(with: [.currentHostOnly])
        pasteboard.setString(text, forType: .string)
        clipboardState.recordRemoteWrite(
            text: text,
            changeCount: pasteboard.changeCount,
            sentAtMs: sentAtMs
        )
        #elseif canImport(UIKit)
        UIPasteboard.general.string = text
        clipboardState.recordRemoteWrite(
            text: text,
            changeCount: UIPasteboard.general.changeCount,
            sentAtMs: sentAtMs
        )
        #endif
    }

    func syncCurrentClipboardToRemote() {
        let changeCount = currentChangeCount()
        let currentText = currentClipboardText()
        guard let text = clipboardState.preferredTextForManualLocalSync(
            currentText: currentText,
            changeCount: changeCount
        ) else {
            return
        }

        let sentAtMs = MirageSharedClipboard.currentTimestampMs()
        clipboardState.recordManualLocalSend(changeCount: changeCount, sentAtMs: sentAtMs)
        onLocalTextChanged(text, UUID(), sentAtMs)
    }

    private func activate() {
        clipboardState.activate(changeCount: currentChangeCount())
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
                self?.observeOrTrackClipboard()
            }
        }

        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.observeOrTrackClipboard()
            }
        }

        // Polling fallback — slower than macOS since notifications are the primary path.
        // UIPasteboard.changeCount is lightweight and does not trigger the paste banner.
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                observeOrTrackClipboard()
            }
        }
        #endif
    }

    private func observeOrTrackClipboard() {
        if autoSync {
            observeLocalClipboardIfNeeded()
        } else {
            trackChangeCountOnly()
        }
    }

    private func trackChangeCountOnly() {
        clipboardState.recordObservedLocalChangeCount(
            currentChangeCount(),
            observedAtMs: MirageSharedClipboard.currentTimestampMs()
        )
    }

    private func observeLocalClipboardIfNeeded() {
        let changeCount = currentChangeCount()
        guard changeCount != clipboardState.lastObservedChangeCount else { return }

        // UIPasteboard.general.string blocks the calling thread for IPC to
        // the pasteboard daemon (can stall 2-8 seconds).  Read it off the
        // main actor to keep the UI responsive.
        Task.detached(priority: .utility) { [weak self] in
            #if os(macOS)
            let text = NSPasteboard.general.string(forType: .string)
            #elseif canImport(UIKit)
            let text = UIPasteboard.general.string
            #else
            let text: String? = nil
            #endif
            await self?.completeClipboardObservation(text: text, changeCount: changeCount)
        }
    }

    @MainActor
    private func completeClipboardObservation(text: String?, changeCount: Int) {
        guard isActive else { return }
        let sentAtMs = MirageSharedClipboard.currentTimestampMs()
        switch clipboardState.observeLocalText(
            text,
            changeCount: changeCount,
            sentAtMs: sentAtMs
        ) {
        case .ignore:
            break
        case let .send(text):
            onLocalTextChanged(text, UUID(), sentAtMs)
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
