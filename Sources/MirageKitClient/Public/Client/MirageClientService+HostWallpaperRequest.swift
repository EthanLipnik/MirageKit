//
//  MirageClientService+HostWallpaperRequest.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/29/26.
//
//  Host wallpaper request bookkeeping.
//

import Foundation
import MirageKit

@MainActor
extension MirageClientService {
    func completeHostWallpaperRequest(_ result: Result<Void, Error>) {
        hostWallpaperRequestID = nil
        hostWallpaperTransferTask?.cancel()
        hostWallpaperTransferTask = nil
        heartbeatGraceDeadline = nil
        guard let continuation = hostWallpaperContinuation else { return }
        hostWallpaperContinuation = nil
        hostWallpaperTimeoutTask?.cancel()
        hostWallpaperTimeoutTask = nil
        continuation.resume(with: result)
    }
}
