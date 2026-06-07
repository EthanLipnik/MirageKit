import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
//
//  MirageClientService+HostWallpaperRequest.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/29/26.
//
//  Host wallpaper request bookkeeping.
//


@MainActor
extension MirageClientService {
    func completeHostWallpaperRequest(_ result: Result<Void, Error>) {
        hostWallpaperRequestID = nil
        heartbeatGraceDeadline = nil
        guard let continuation = hostWallpaperContinuation else { return }
        hostWallpaperContinuation = nil
        hostWallpaperTimeoutTask?.cancel()
        hostWallpaperTimeoutTask = nil
        continuation.resume(with: result)
    }
}
