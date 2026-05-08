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

private struct HostClipboardSnapshot: Sendable {
    let changeCount: Int
    let item: MirageSharedClipboardItem
}

private actor HostClipboardSnapshotReader {
    static let shared = HostClipboardSnapshotReader()

    private let fileManager = FileManager.default

    func changeCount() -> Int {
        NSPasteboard.general.changeCount
    }

    func snapshot() -> HostClipboardSnapshot {
        let pasteboard = NSPasteboard.general
        return HostClipboardSnapshot(
            changeCount: pasteboard.changeCount,
            item: Self.item(from: pasteboard)
        )
    }

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
            if let url = materializeReceivedFile(item) as NSURL? {
                pasteboard.writeObjects([url])
            }
        case .unsupported:
            break
        }
        return pasteboard.changeCount
    }

    func cleanupReceivedFiles() {
        try? fileManager.removeItem(at: receivedClipboardDirectory)
    }

    private var receivedClipboardDirectory: URL {
        fileManager.temporaryDirectory
            .appendingPathComponent("MirageSharedClipboard", isDirectory: true)
            .appendingPathComponent("Host", isDirectory: true)
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
        let representation = SharedClipboardRepresentation(
            kind: kind,
            contentType: contentType,
            filename: filename,
            byteCount: payload.count
        )
        guard payload.count <= MirageSharedClipboard.maximumPayloadBytes(for: representation) else {
            return MirageSharedClipboardItem(
                representation: representation,
                payload: nil
            )
        }
        return MirageSharedClipboardItem(
            representation: representation,
            payload: payload
        )
    }
}

private extension NSImage {
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
            let changeCount = await HostClipboardSnapshotReader.shared.changeCount()
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
            let initialCount = await HostClipboardSnapshotReader.shared.changeCount()
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
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, self.isActive else { continue }
                await self.sendHostClipboardIfChanged()
            }
        }
    }

    private func sendHostClipboardIfChanged() async {
        let snapshot = await HostClipboardSnapshotReader.shared.snapshot()
        guard let localSend = clipboardState.prepareLocalDeclaration(
            item: snapshot.item,
            changeCount: snapshot.changeCount
        ) else {
            return
        }
        await onLocalSend?(localSend, MirageSharedClipboard.currentTimestampMs())
    }
}
