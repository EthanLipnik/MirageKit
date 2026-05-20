//
//  MirageAppAtlasRenderFanout.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/18/26.
//
//  Per-logical-stream render fanout for shared app-atlas media streams.
//

import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import MirageKit

struct MirageAppAtlasRenderTarget: Equatable {
    let streamID: StreamID
    let region: MirageAppAtlasRegion
}

final class MirageAppAtlasRenderFanout: @unchecked Sendable {
    static let shared = MirageAppAtlasRenderFanout()

    private final class TargetState {
        let streamID: StreamID
        var region: MirageAppAtlasRegion
        let cropper = MiragePixelBufferCropper()

        init(streamID: StreamID, region: MirageAppAtlasRegion) {
            self.streamID = streamID
            self.region = region
        }
    }

    private struct EnqueuedFrame {
        let streamID: StreamID
        let pixelBuffer: CVPixelBuffer
        let contentRect: CGRect
    }

    private let lock = NSLock()
    private var targetsByMediaStreamID: [StreamID: [StreamID: TargetState]] = [:]
    private var mediaStreamIDByLogicalStreamID: [StreamID: StreamID] = [:]

    private init() {}

    func setTargets(_ targets: [MirageAppAtlasRenderTarget], for mediaStreamID: StreamID) {
        var removedStreamIDs: [StreamID] = []
        lock.lock()
        let previousTargets = targetsByMediaStreamID[mediaStreamID] ?? [:]
        var nextTargets: [StreamID: TargetState] = [:]
        nextTargets.reserveCapacity(targets.count)

        for target in targets {
            let state = previousTargets[target.streamID] ?? TargetState(
                streamID: target.streamID,
                region: target.region
            )
            state.region = target.region
            nextTargets[target.streamID] = state
            mediaStreamIDByLogicalStreamID[target.streamID] = mediaStreamID
        }

        for streamID in previousTargets.keys where nextTargets[streamID] == nil {
            mediaStreamIDByLogicalStreamID.removeValue(forKey: streamID)
            removedStreamIDs.append(streamID)
        }

        if nextTargets.isEmpty {
            targetsByMediaStreamID.removeValue(forKey: mediaStreamID)
        } else {
            targetsByMediaStreamID[mediaStreamID] = nextTargets
        }
        lock.unlock()

        for streamID in removedStreamIDs {
            MirageRenderStreamStore.shared.clear(for: streamID)
        }
    }

    func mediaStreamID(forLogicalStreamID streamID: StreamID) -> StreamID? {
        lock.lock()
        let mediaStreamID = mediaStreamIDByLogicalStreamID[streamID]
        lock.unlock()
        return mediaStreamID
    }

    func trimForMemoryPressure(streamIDs: Set<StreamID>) {
        lock.lock()
        let targets = targetsByMediaStreamID.values
            .flatMap(\.values)
            .filter { streamIDs.isEmpty || streamIDs.contains($0.streamID) }
        for target in targets {
            target.cropper.reset()
        }
        lock.unlock()
    }

    @discardableResult
    func enqueueIfNeeded(
        pixelBuffer: CVPixelBuffer,
        contentRect: CGRect,
        decodeTime: CFAbsoluteTime,
        presentationTime: CMTime,
        remotePresentationTime: CMTime,
        for mediaStreamID: StreamID
    ) -> Bool {
        lock.lock()
        guard let targets = targetsByMediaStreamID[mediaStreamID], !targets.isEmpty else {
            lock.unlock()
            return false
        }

        var enqueuedFrames: [EnqueuedFrame] = []
        enqueuedFrames.reserveCapacity(targets.count)
        for target in targets.values {
            guard let cropResult = target.cropper.crop(
                pixelBuffer,
                to: target.region.pixelRect,
                allowInvalidCropFallback: false
            ) else {
                continue
            }
            enqueuedFrames.append(
                EnqueuedFrame(
                    streamID: target.streamID,
                    pixelBuffer: cropResult.pixelBuffer,
                    contentRect: cropResult.contentRect
                )
            )
        }
        lock.unlock()

        guard !enqueuedFrames.isEmpty else { return true }
        for frame in enqueuedFrames {
            _ = MirageRenderStreamStore.shared.enqueue(
                pixelBuffer: frame.pixelBuffer,
                contentRect: frame.contentRect,
                decodeTime: decodeTime,
                presentationTime: presentationTime,
                remotePresentationTime: remotePresentationTime,
                for: frame.streamID
            )
        }
        return true
    }
}
