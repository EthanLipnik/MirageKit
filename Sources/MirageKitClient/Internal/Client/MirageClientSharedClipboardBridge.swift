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

private struct ClientClipboardSnapshot: Sendable {
    let changeCount: Int
    let item: MirageSharedClipboardItem
}

private actor ClientClipboardSnapshotReader {
    static let shared = ClientClipboardSnapshotReader()

    private let fileManager = FileManager.default

    func snapshot() -> ClientClipboardSnapshot {
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
        return ClientClipboardSnapshot(changeCount: 0, item: .unsupported())
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
            if let url = materializeReceivedFile(item) as NSURL? {
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
            if let url = materializeReceivedFile(item) {
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

    func cleanupReceivedFiles() {
        try? fileManager.removeItem(at: receivedClipboardDirectory)
    }

    private var receivedClipboardDirectory: URL {
        fileManager.temporaryDirectory
            .appendingPathComponent("MirageSharedClipboard", isDirectory: true)
            .appendingPathComponent("Client", isDirectory: true)
    }

    private func materializeReceivedFile(_ item: MirageSharedClipboardItem) -> URL? {
        guard item.representation.kind == .file,
              let payload = item.payload else {
            return nil
        }
        let filename = sanitizedFilename(item.representation.filename ?? "Mirage Clipboard Item")
        let directory = receivedClipboardDirectory
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(filename, isDirectory: false)
            try payload.write(to: url, options: [.atomic])
            return url
        } catch {
            return nil
        }
    }

    private func sanitizedFilename(_ filename: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:")
        let sanitized = filename
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "Mirage Clipboard Item" : sanitized
    }

    #if os(macOS)
    private static func item(from pasteboard: NSPasteboard) -> MirageSharedClipboardItem {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [NSURL],
           let item = fileItem(from: urls.map { $0 as URL }) {
            return item
        }

        if let image = NSImage(pasteboard: pasteboard),
           let payload = image.pngData {
            return item(kind: .image, contentType: "public.png", filename: nil, payload: payload)
        }

        if let text = pasteboard.string(forType: .string),
           let payload = text.data(using: .utf8) {
            return item(kind: .text, contentType: "public.utf8-plain-text", filename: nil, payload: payload)
        }

        return .unsupported()
    }
    #endif

    #if canImport(UIKit)
    private static func item(from pasteboard: UIPasteboard) -> MirageSharedClipboardItem {
        if pasteboard.hasStrings,
           let text = pasteboard.string,
           let payload = text.data(using: .utf8) {
            return item(kind: .text, contentType: "public.utf8-plain-text", filename: nil, payload: payload)
        }

        if pasteboard.hasURLs,
           let urls = pasteboard.urls,
           let item = fileItem(from: urls) {
            return item
        }

        if pasteboard.hasImages,
           let image = pasteboard.image,
           let payload = image.pngData() {
            return item(kind: .image, contentType: "public.png", filename: nil, payload: payload)
        }

        return .unsupported()
    }
    #endif

    private static func fileItem(from urls: [URL]) -> MirageSharedClipboardItem? {
        guard let url = urls.first, url.isFileURL else { return nil }
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentTypeKey]),
              values.isRegularFile == true,
              let byteCount = values.fileSize else {
            return nil
        }
        let representation = SharedClipboardRepresentation(
            kind: .file,
            contentType: values.contentType?.identifier,
            filename: url.lastPathComponent,
            byteCount: byteCount
        )
        guard byteCount <= MirageSharedClipboard.maximumPayloadBytes,
              let payload = try? Data(contentsOf: url),
              payload.count <= MirageSharedClipboard.maximumPayloadBytes else {
            return MirageSharedClipboardItem(representation: representation, payload: nil)
        }
        return MirageSharedClipboardItem(
            representation: representation,
            payload: payload
        )
    }

    private static func item(
        kind: SharedClipboardRepresentationKind,
        contentType: String?,
        filename: String?,
        payload: Data
    ) -> MirageSharedClipboardItem {
        guard payload.count <= MirageSharedClipboard.maximumPayloadBytes else {
            return MirageSharedClipboardItem(
                representation: SharedClipboardRepresentation(
                    kind: kind,
                    contentType: contentType,
                    filename: filename,
                    byteCount: payload.count
                ),
                payload: nil
            )
        }
        return MirageSharedClipboardItem(
            representation: SharedClipboardRepresentation(
                kind: kind,
                contentType: contentType,
                filename: filename,
                byteCount: payload.count
            ),
            payload: payload
        )
    }
}

#if os(macOS)
private extension NSImage {
    var pngData: Data? {
        guard let tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffRepresentation) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }
}
#endif

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
        let changeCount = await ClientClipboardSnapshotReader.shared.changeCount()
        clipboardState.recordRemoteDeclaration(
            changeCount: changeCount,
            orderingToken: orderingToken
        )
        MirageLogger.client("Recorded shared clipboard declaration from host: sentAtMs=\(sentAtMs)")
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

    func prepareCurrentClipboardManualSend()
        async -> (localSend: MirageSharedClipboardLocalSend, sentAtMs: Int64)? {
        let currentChangeCount = await ClientClipboardSnapshotReader.shared.changeCount()
        if clipboardState.shouldSuppressLocalSend(changeCount: currentChangeCount) {
            clipboardState.recordObservedChangeCount(currentChangeCount)
            MirageLogger.client("Shared clipboard manual sync skipped: host clipboard is newer")
            return nil
        }

        let snapshot = await ClientClipboardSnapshotReader.shared.snapshot()
        guard let localSend = clipboardState.prepareLocalSend(
            currentItem: snapshot.item,
            changeCount: snapshot.changeCount
        ) else {
            MirageLogger.client("Shared clipboard manual sync skipped: no local clipboard change")
            return nil
        }

        let sentAtMs = MirageSharedClipboard.currentTimestampMs()
        return (localSend, sentAtMs)
    }

    private func activate() async {
        let changeCount = await ClientClipboardSnapshotReader.shared.changeCount()
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
