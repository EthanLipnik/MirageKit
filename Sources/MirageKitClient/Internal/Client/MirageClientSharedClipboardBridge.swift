//
//  MirageClientSharedClipboardBridge.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/11/26.
//

import Foundation
import MirageKit
import UniformTypeIdentifiers

#if canImport(AppKit)
import AppKit
#endif

#if canImport(UIKit)
import UIKit
#endif

/// Snapshot of the client pasteboard state used for shared-clipboard ordering.
private struct ClientClipboardSnapshot: Sendable {
    /// Pasteboard change count captured with the item.
    let changeCount: Int

    /// Serialized clipboard item derived from the current pasteboard contents.
    let item: MirageSharedClipboardItem
}

/// Reads and writes platform pasteboards on an actor so clipboard operations stay serialized.
private actor ClientClipboardSnapshotReader {
    static let shared = ClientClipboardSnapshotReader()
    private static let receivedClipboardSide = "Client"

    private let fileManager = FileManager.default

    /// Current platform pasteboard change count plus a serialized Mirage clipboard item.
    var snapshot: ClientClipboardSnapshot {
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        return ClientClipboardSnapshot(
            changeCount: pasteboard.changeCount,
            item: Self.item(from: pasteboard)
        )
        #elseif canImport(UIKit)
        let pasteboard = UIPasteboard.general
        return ClientClipboardSnapshot(
            changeCount: pasteboard.changeCount,
            item: Self.item(from: pasteboard)
        )
        #else
        return ClientClipboardSnapshot(
            changeCount: 0,
            item: .unsupported()
        )
        #endif
    }

    /// Current platform pasteboard change count.
    var changeCount: Int {
        #if os(macOS)
        NSPasteboard.general.changeCount
        #elseif canImport(UIKit)
        UIPasteboard.general.changeCount
        #else
        0
        #endif
    }

    /// Applies a host-provided clipboard item to the local platform pasteboard.
    func applyItem(_ item: MirageSharedClipboardItem) -> Int {
        cleanupReceivedFiles()
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        _ = pasteboard.prepareForNewContents(with: [.currentHostOnly])
        switch item.representation.kind {
        case .text:
            if let payload = item.payload,
               let text = String(data: payload, encoding: .utf8) {
                pasteboard.setString(text, forType: .string)
            }
        case .image:
            if let payload = item.payload,
               let image = NSImage(data: payload) {
                pasteboard.writeObjects([image])
            }
        case .file:
            if let url = mirageMaterializeReceivedSharedClipboardFile(
                item,
                side: Self.receivedClipboardSide,
                fileManager: fileManager
            ) as NSURL? {
                pasteboard.writeObjects([url])
            }
        case .unsupported:
            break
        }
        return pasteboard.changeCount
        #elseif canImport(UIKit)
        let pasteboard = UIPasteboard.general
        switch item.representation.kind {
        case .text:
            if let payload = item.payload,
               let text = String(data: payload, encoding: .utf8) {
                pasteboard.string = text
            }
        case .image:
            if let payload = item.payload,
               let image = UIImage(data: payload) {
                pasteboard.image = image
            }
        case .file:
            if let url = mirageMaterializeReceivedSharedClipboardFile(
                item,
                side: Self.receivedClipboardSide,
                fileManager: fileManager
            ) {
                pasteboard.urls = [url]
            }
        case .unsupported:
            break
        }
        return pasteboard.changeCount
        #else
        return 0
        #endif
    }

    /// Removes temporary files materialized for received clipboard file payloads.
    func cleanupReceivedFiles() {
        let directory = mirageReceivedSharedClipboardDirectory(
            side: Self.receivedClipboardSide,
            fileManager: fileManager
        )
        guard fileManager.fileExists(atPath: directory.path) else { return }
        do {
            try fileManager.removeItem(at: directory)
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to clean up received clipboard files: ")
        }
    }

    #if os(macOS)
    /// Converts the current AppKit pasteboard contents into a Mirage clipboard item.
    private static func item(from pasteboard: NSPasteboard) -> MirageSharedClipboardItem {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [NSURL],
           let item = mirageSharedClipboardFileItem(from: urls.map { $0 as URL }) {
            return item
        }

        if let image = NSImage(pasteboard: pasteboard),
           let payload = image.pngData {
            return mirageSharedClipboardItem(kind: .image, contentType: "public.png", filename: nil, payload: payload)
        }

        if let text = pasteboard.string(forType: .string),
           let payload = text.data(using: .utf8) {
            return mirageSharedClipboardItem(
                kind: .text,
                contentType: "public.utf8-plain-text",
                filename: nil,
                payload: payload
            )
        }

        return .unsupported()
    }
    #elseif canImport(UIKit)
    /// Converts the current UIKit pasteboard contents into a Mirage clipboard item.
    private static func item(from pasteboard: UIPasteboard) -> MirageSharedClipboardItem {
        if pasteboard.hasStrings,
           let text = pasteboard.string,
           let payload = text.data(using: .utf8) {
            return mirageSharedClipboardItem(
                kind: .text,
                contentType: "public.utf8-plain-text",
                filename: nil,
                payload: payload
            )
        }

        if pasteboard.hasURLs,
           let urls = pasteboard.urls,
           let item = mirageSharedClipboardFileItem(from: urls) {
            return item
        }

        if pasteboard.hasImages,
           let image = pasteboard.image,
           let payload = image.pngData() {
            return mirageSharedClipboardItem(kind: .image, contentType: "public.png", filename: nil, payload: payload)
        }

        return .unsupported()
    }
    #endif
}

#if os(macOS)
private extension NSImage {
    /// PNG representation used for shared-clipboard image transfer.
    var pngData: Data? {
        guard let tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffRepresentation) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }
}
#endif

/// Result of preparing an explicit client-to-host clipboard sync.
enum MirageClientSharedClipboardManualSyncPreparation: Sendable, Equatable {
    /// Send the current local clipboard contents to the host.
    case send(localSend: MirageSharedClipboardLocalSend, sentAtMs: Int64)

    /// Skip sending because ordering state shows the host already has the newer clipboard.
    case hostAlreadyCurrent
}

@MainActor
final class MirageClientSharedClipboardBridge {
    private var clipboardState = MirageSharedClipboardState()
    private var isActive = false
    #if canImport(UIKit)
    private var pasteboardObserver: NSObjectProtocol?
    #endif

    init() {}

    deinit {
        #if canImport(UIKit)
        MainActor.assumeIsolated {
            if let pasteboardObserver {
                NotificationCenter.default.removeObserver(pasteboardObserver)
            }
        }
        #endif
    }

    func setActive(_ isActive: Bool) async {
        let wasActive = self.isActive

        if isActive == wasActive { return }

        self.isActive = isActive
        if isActive {
            await activate()
        } else {
            await deactivate()
        }
    }

    func noteRemoteDeclaration(
        orderingToken: MirageSharedClipboardOrderingToken,
        sentAtMs: Int64
    ) async {
        guard clipboardState.shouldApplyRemoteUpdate(orderingToken: orderingToken) else {
            MirageLogger.client("Ignoring stale shared clipboard declaration from host")
            return
        }
        let changeCount = await ClientClipboardSnapshotReader.shared.changeCount
        clipboardState.recordRemoteDeclaration(
            changeCount: changeCount,
            orderingToken: orderingToken,
            observedAtMs: MirageSharedClipboard.currentTimestampMs()
        )
        MirageLogger.client("Recorded shared clipboard declaration from host: sentAtMs=\(sentAtMs)")
    }

    func noteRemoteTransferObservation(
        orderingToken: MirageSharedClipboardOrderingToken,
        sentAtMs: Int64
    ) async {
        let changeCount = await ClientClipboardSnapshotReader.shared.changeCount
        let recorded = clipboardState.recordRemoteTransferObservation(
            changeCount: changeCount,
            orderingToken: orderingToken
        )
        guard recorded else { return }
        MirageLogger.client("Recorded shared clipboard payload observation from host: sentAtMs=\(sentAtMs)")
    }

    func applyRemoteItem(
        _ item: MirageSharedClipboardItem,
        orderingToken: MirageSharedClipboardOrderingToken,
        sentAtMs: Int64
    ) async {
        guard clipboardState.shouldApplyRemoteUpdate(orderingToken: orderingToken) else {
            MirageLogger.client("Ignoring stale shared clipboard update from host")
            return
        }

        let changeCount = await ClientClipboardSnapshotReader.shared.applyItem(item)
        clipboardState.recordRemoteWrite(
            changeCount: changeCount,
            orderingToken: orderingToken
        )
        MirageLogger.client(
            "Applied shared clipboard update from host: kind=\(item.representation.kind.rawValue), bytes=\(item.representation.byteCount), sentAtMs=\(sentAtMs)"
        )
    }

    func prepareCurrentClipboardManualSync()
        async -> MirageClientSharedClipboardManualSyncPreparation? {
        let currentChangeCount = await ClientClipboardSnapshotReader.shared.changeCount
        let nowMs = MirageSharedClipboard.currentTimestampMs()
        if clipboardState.shouldSuppressLocalSend(changeCount: currentChangeCount, nowMs: nowMs) {
            clipboardState.recordSuppressedLocalSend(changeCount: currentChangeCount)
            MirageLogger.client("Shared clipboard manual sync skipped: host clipboard is newer")
            return .hostAlreadyCurrent
        }

        let latestChangeCount = await ClientClipboardSnapshotReader.shared.changeCount
        if latestChangeCount != currentChangeCount,
           clipboardState.shouldSuppressLocalSend(changeCount: latestChangeCount, nowMs: nowMs) {
            clipboardState.recordSuppressedLocalSend(changeCount: latestChangeCount)
            MirageLogger.client("Shared clipboard manual sync skipped: host clipboard is current")
            return .hostAlreadyCurrent
        }

        let snapshot = await ClientClipboardSnapshotReader.shared.snapshot
        guard snapshot.item.representation.kind != .unsupported,
              snapshot.item.payload != nil else {
            clipboardState.recordSuppressedLocalSend(changeCount: snapshot.changeCount)
            MirageLogger.client("Shared clipboard manual sync skipped: local clipboard has no transferable payload")
            return .hostAlreadyCurrent
        }
        guard let localSend = clipboardState.prepareLocalSend(
            currentItem: snapshot.item,
            changeCount: snapshot.changeCount,
            nowMs: nowMs
        ) else {
            MirageLogger.client("Shared clipboard manual sync skipped: no local clipboard change")
            return nil
        }

        let sentAtMs = MirageSharedClipboard.currentTimestampMs()
        return .send(localSend: localSend, sentAtMs: sentAtMs)
    }

    private func activate() async {
        let changeCount = await ClientClipboardSnapshotReader.shared.changeCount
        clipboardState.activate(changeCount: changeCount)
        #if canImport(UIKit)
        pasteboardObserver = NotificationCenter.default.addObserver(
            forName: UIPasteboard.changedNotification,
            object: UIPasteboard.general,
            queue: nil
        ) { _ in
            MirageLogger.client("Client pasteboard change observed")
        }
        #endif
    }

    private func deactivate() async {
        clipboardState.deactivate()
        #if canImport(UIKit)
        if let pasteboardObserver {
            NotificationCenter.default.removeObserver(pasteboardObserver)
            self.pasteboardObserver = nil
        }
        #endif
        await ClientClipboardSnapshotReader.shared.cleanupReceivedFiles()
    }
}
