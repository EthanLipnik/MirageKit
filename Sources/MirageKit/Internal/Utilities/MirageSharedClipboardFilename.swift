//
//  MirageSharedClipboardFilename.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageMedia
import MirageWire
import Foundation

/// Creates a shared clipboard item for the first regular file URL in a pasteboard URL list.
package func mirageSharedClipboardFileItem(from urls: [URL]) -> MirageSharedClipboardItem? {
    guard let url = urls.first, url.isFileURL else { return nil }
    guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentTypeKey]),
          values.isRegularFile == true,
          let byteCount = values.fileSize else {
        return nil
    }
    let representation = MirageWire.SharedClipboardRepresentation(
        kind: .file,
        contentType: values.contentType?.identifier,
        filename: url.lastPathComponent,
        byteCount: byteCount
    )
    guard byteCount <= MirageSharedClipboard.maximumBinaryPayloadBytes,
          let payload = try? Data(contentsOf: url),
          payload.count <= MirageSharedClipboard.maximumBinaryPayloadBytes else {
        return MirageSharedClipboardItem(representation: representation, payload: nil)
    }
    return MirageSharedClipboardItem(
        representation: representation,
        payload: payload
    )
}

/// Wraps a pasteboard payload in a shared clipboard item, dropping oversize payload bytes.
package func mirageSharedClipboardItem(
    kind: MirageWire.SharedClipboardRepresentationKind,
    contentType: String?,
    filename: String?,
    payload: Data
) -> MirageSharedClipboardItem {
    let representation = MirageWire.SharedClipboardRepresentation(
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

/// Temporary directory used for files received through shared clipboard sync.
package func mirageReceivedSharedClipboardDirectory(side: String, fileManager: FileManager = .default) -> URL {
    fileManager.temporaryDirectory
        .appendingPathComponent("MirageSharedClipboard", isDirectory: true)
        .appendingPathComponent(side, isDirectory: true)
}

/// Writes a received shared-clipboard file payload into a temporary side-specific directory.
package func mirageMaterializeReceivedSharedClipboardFile(
    _ item: MirageSharedClipboardItem,
    side: String,
    fileManager: FileManager = .default
) -> URL? {
    guard item.representation.kind == .file,
          let payload = item.payload else {
        return nil
    }
    let filename = mirageSanitizedSharedClipboardFilename(
        item.representation.filename ?? "Mirage Clipboard Item"
    )
    let directory = mirageReceivedSharedClipboardDirectory(side: side, fileManager: fileManager)
    do {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(filename, isDirectory: false)
        try payload.write(to: url, options: [.atomic])
        return url
    } catch {
        return nil
    }
}

/// Returns a filesystem-safe filename for materialized shared clipboard files.
package func mirageSanitizedSharedClipboardFilename(_ filename: String) -> String {
    let invalid = CharacterSet(charactersIn: "/:")
    let sanitized = filename
        .components(separatedBy: invalid)
        .joined(separator: "-")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return sanitized.isEmpty ? "Mirage Clipboard Item" : sanitized
}
