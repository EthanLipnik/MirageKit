//
//  MirageHostSharedClipboardBridge.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/11/26.
//

import AppKit
import Foundation
import MirageKit
import UniformTypeIdentifiers

/// Snapshot of the host pasteboard state used for shared-clipboard ordering.
private struct HostClipboardSnapshot: Sendable {
    /// Pasteboard change count captured with the item.
    let changeCount: Int

    /// Serialized clipboard item derived from the current pasteboard contents.
    let item: MirageSharedClipboardItem
}

/// Reads and writes `NSPasteboard` on an actor so host clipboard polling stays serialized.
private actor HostClipboardSnapshotReader {
    static let shared = HostClipboardSnapshotReader()
    private static let receivedClipboardSide = "Host"

    private let fileManager = FileManager.default

    /// Current pasteboard change count.
    var changeCount: Int {
        NSPasteboard.general.changeCount
    }

    /// Current pasteboard change count plus a serialized Mirage clipboard item.
    var snapshot: HostClipboardSnapshot {
        let pasteboard = NSPasteboard.general
        return HostClipboardSnapshot(
            changeCount: pasteboard.changeCount,
            item: Self.item(from: pasteboard)
        )
    }

    /// Applies a client-provided clipboard item to the host pasteboard.
    func applyItem(_ item: MirageSharedClipboardItem) -> Int {
        cleanupReceivedFiles()
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
            MirageLogger.error(.host, error: error, message: "Failed to clean up received clipboard files: ")
        }
    }

    /// Converts the current host pasteboard contents into a Mirage clipboard item.
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
}

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

@MainActor
final class MirageHostSharedClipboardBridge {
    var onLocalSend: ((MirageSharedClipboardLocalSend, Int64) async -> Void)?

    private var clipboardState = MirageSharedClipboardState()
    private var isActive = false
    private var observationTask: Task<Void, Never>?

    init() {}

    deinit {
        observationTask?.cancel()
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

    func applyRemoteItem(
        _ item: MirageSharedClipboardItem,
        orderingToken: MirageSharedClipboardOrderingToken,
        sentAtMs: Int64
    ) async {
        guard clipboardState.shouldApplyRemoteUpdate(orderingToken: orderingToken) else {
            MirageLogger.host("Ignoring stale shared clipboard update from client")
            return
        }

        guard item.payload != nil else {
            let changeCount = await HostClipboardSnapshotReader.shared.changeCount
            clipboardState.recordRemoteDeclaration(
                changeCount: changeCount,
                orderingToken: orderingToken
            )
            MirageLogger.host("Recorded metadata-only shared clipboard update from client")
            return
        }

        let changeCount = await HostClipboardSnapshotReader.shared.applyItem(item)
        clipboardState.recordRemoteWrite(
            changeCount: changeCount,
            orderingToken: orderingToken
        )
        MirageLogger.host(
            "Applied shared clipboard update from client: kind=\(item.representation.kind.rawValue), bytes=\(item.representation.byteCount), sentAtMs=\(sentAtMs)"
        )
    }

    private func activate() {
        observationTask?.cancel()
        Task { [weak self] in
            guard let self else { return }
            let initialCount = await HostClipboardSnapshotReader.shared.changeCount
            guard self.isActive else { return }
            clipboardState.activate(changeCount: initialCount)
            startObservingHostClipboard()
        }
    }

    private func deactivate() {
        observationTask?.cancel()
        observationTask = nil
        clipboardState.deactivate()
        Task {
            await HostClipboardSnapshotReader.shared.cleanupReceivedFiles()
        }
    }

    private func startObservingHostClipboard() {
        observationTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    break
                }
                guard let self, self.isActive else { continue }
                await self.sendHostClipboardIfChanged()
            }
        }
    }

    private func sendHostClipboardIfChanged() async {
        let snapshot = await HostClipboardSnapshotReader.shared.snapshot
        guard let localSend = clipboardState.prepareLocalDeclaration(
            item: snapshot.item,
            changeCount: snapshot.changeCount
        ) else {
            return
        }
        await onLocalSend?(localSend, MirageSharedClipboard.currentTimestampMs())
    }
}
