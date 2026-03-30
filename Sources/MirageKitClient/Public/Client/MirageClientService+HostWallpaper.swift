//
//  MirageClientService+HostWallpaper.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/29/26.
//
//  Client host-wallpaper transfer flow.
//

import Foundation
import Loom
import MirageKit

@MainActor
extension MirageClientService {
    func downloadHostWallpaper(
        requestID: UUID,
        fileName: String
    ) async throws -> URL {
        let rid = requestID.uuidString.lowercased()
        guard let transferEngine else {
            throw MirageError.protocolError("Missing authenticated Loom transfer engine for host wallpaper transfer")
        }
        let incomingTransfer = try await awaitIncomingTransfer(
            kind: "host-wallpaper",
            requestID: requestID
        )
        MirageLogger.client(
            "Accepted host wallpaper transfer offer requestID=\(rid) bytes=\(incomingTransfer.offer.byteLength)"
        )

        let destinationURL = uniqueWallpaperDestinationURL(fileName: fileName)
        let sink = try LoomFileTransferSink(url: destinationURL)
        try await incomingTransfer.accept(using: sink)

        let terminalProgress = await terminalWallpaperProgress(from: incomingTransfer.progressEvents)
        switch terminalProgress?.state {
        case .completed:
            MirageLogger.client(
                "Completed host wallpaper download requestID=\(rid) file=\(destinationURL.lastPathComponent)"
            )
            return destinationURL
        case .cancelled, .declined:
            try? FileManager.default.removeItem(at: destinationURL)
            throw CancellationError()
        default:
            try? FileManager.default.removeItem(at: destinationURL)
            throw MirageError.protocolError("Host wallpaper transfer did not complete")
        }
    }

    private func uniqueWallpaperDestinationURL(fileName: String) -> URL {
        let sanitized = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = sanitized.isEmpty ? "MirageHostWallpaper.jpg" : URL(fileURLWithPath: sanitized).lastPathComponent
        let uniqueName = "\(UUID().uuidString)-\(baseName)"
        return FileManager.default.temporaryDirectory.appending(path: uniqueName)
    }

    private func terminalWallpaperProgress(
        from stream: AsyncStream<LoomTransferProgress>
    ) async -> LoomTransferProgress? {
        var lastProgress: LoomTransferProgress?
        for await progress in stream {
            lastProgress = progress
            switch progress.state {
            case .completed, .cancelled, .failed, .declined:
                return progress
            case .offered, .waitingForAcceptance, .transferring:
                break
            }
        }
        return lastProgress
    }
}
