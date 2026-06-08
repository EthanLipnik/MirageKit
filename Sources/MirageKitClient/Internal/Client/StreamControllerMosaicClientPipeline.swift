//
//  StreamControllerMosaicClientPipeline.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/6/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation

final class StreamControllerMosaicRetainedFramePresenter: @unchecked Sendable {
    private static let maximumFirstCommitWaitSeconds: CFAbsoluteTime = 0.20

    private let streamID: StreamID
    private let context = CIContext(options: nil)
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let lock = NSLock()
    private var activePlanEpoch: UInt32?
    private var activeLogicalSize = MiragePixelSize(width: 0, height: 0)
    private var activePlanFirstDecodeTime: CFAbsoluteTime = 0
    private var completedPlanEpoch: UInt32?
    private var retainedImages: [UInt16: CIImage] = [:]

    init(streamID: StreamID) {
        self.streamID = streamID
    }

    func reset() {
        lock.lock()
        activePlanEpoch = nil
        activeLogicalSize = MiragePixelSize(width: 0, height: 0)
        activePlanFirstDecodeTime = 0
        completedPlanEpoch = nil
        retainedImages.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    func enqueueDecodedUnit(
        pixelBuffer: CVPixelBuffer,
        presentationTime: CMTime,
        mediaUnitIndex: UInt16,
        plan: MirageMosaicTilePlan,
        presentationRect: MiragePixelRect
    ) {
        guard !plan.logicalSize.isEmpty,
              !presentationRect.size.isEmpty else {
            return
        }

        let output: CVPixelBuffer?
        lock.lock()
        if activePlanEpoch != plan.epoch || activeLogicalSize != plan.logicalSize {
            activePlanEpoch = plan.epoch
            activeLogicalSize = plan.logicalSize
            activePlanFirstDecodeTime = CFAbsoluteTimeGetCurrent()
            completedPlanEpoch = nil
            retainedImages.removeAll(keepingCapacity: false)
        }
        retainedImages[mediaUnitIndex] = Self.image(
            from: pixelBuffer,
            presentationRect: presentationRect,
            canvasHeight: plan.logicalSize.height
        )
        if shouldRenderRetainedFrameLocked(plan: plan) {
            output = renderRetainedFrameLocked(plan: plan)
            completedPlanEpoch = plan.epoch
        } else {
            output = nil
        }
        lock.unlock()

        guard let output else { return }
        let decodeTime = CFAbsoluteTimeGetCurrent()
        _ = MirageRenderStreamStore.shared.enqueue(
            pixelBuffer: output,
            contentRect: CGRect(
                x: 0,
                y: 0,
                width: CGFloat(plan.logicalSize.width),
                height: CGFloat(plan.logicalSize.height)
            ),
            decodeTime: decodeTime,
            presentationTime: presentationTime,
            for: streamID
        )
    }

    private func shouldRenderRetainedFrameLocked(plan: MirageMosaicTilePlan) -> Bool {
        if completedPlanEpoch == plan.epoch {
            return true
        }
        let firstCommitTargetCount = min(plan.codecUnits.count, 16)
        guard retainedImages.count < firstCommitTargetCount else {
            return true
        }
        return CFAbsoluteTimeGetCurrent() - activePlanFirstDecodeTime >= Self.maximumFirstCommitWaitSeconds
    }

    private func renderRetainedFrameLocked(plan: MirageMosaicTilePlan) -> CVPixelBuffer? {
        let width = plan.logicalSize.width
        let height = plan.logicalSize.height
        var output: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &output
        )
        guard status == kCVReturnSuccess, let output else { return nil }

        let canvas = retainedImages.values.reduce(CIImage(color: .black).cropped(to: CGRect(
            x: 0,
            y: 0,
            width: CGFloat(width),
            height: CGFloat(height)
        ))) { partial, image in
            image.composited(over: partial)
        }
        context.render(
            canvas,
            to: output,
            bounds: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)),
            colorSpace: colorSpace
        )
        return output
    }

    private static func image(
        from pixelBuffer: CVPixelBuffer,
        presentationRect: MiragePixelRect,
        canvasHeight: Int
    ) -> CIImage {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let width = CGFloat(max(1, presentationRect.width))
        let height = CGFloat(max(1, presentationRect.height))
        let scaleX = width / max(1, image.extent.width)
        let scaleY = height / max(1, image.extent.height)
        let destinationX = CGFloat(presentationRect.x)
        let destinationY = CGFloat(canvasHeight - presentationRect.y - presentationRect.height)
        return image
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .transformed(by: CGAffineTransform(translationX: destinationX, y: destinationY))
    }
}

final class StreamControllerMosaicDependencyState: @unchecked Sendable {
    enum ValidationResult: Equatable, Sendable {
        case accepted
        case stale(retainedVersion: UInt32, tileVersion: UInt32)
        case missingDependency
        case dependencyMismatch(retainedVersion: UInt32, expectedVersion: UInt32)
    }

    private struct PendingDecodeKey: Hashable {
        let mediaUnitIndex: UInt16
        let mediaEpoch: CMTimeValue
    }

    private let lock = NSLock()
    private var activePlanEpoch: UInt32?
    private var retainedTileVersionsByMediaUnitIndex: [UInt16: UInt32] = [:]
    private var pendingTileVersionsByDecodeKey: [PendingDecodeKey: UInt32] = [:]

    func validate(_ unit: StreamControllerMosaicMediaUnitReassembler.CompletedUnit) -> ValidationResult {
        lock.lock()
        defer { lock.unlock() }

        resetForPlanEpochIfNeeded(unit.tilePlanEpoch)
        guard !unit.isKeyframe else { return .accepted }
        guard let retainedVersion = retainedTileVersionsByMediaUnitIndex[unit.mediaUnitIndex] else {
            return .missingDependency
        }
        if unit.tileVersion <= retainedVersion {
            return .stale(retainedVersion: retainedVersion, tileVersion: unit.tileVersion)
        }
        guard retainedVersion == unit.dependencyVersion else {
            return .dependencyMismatch(
                retainedVersion: retainedVersion,
                expectedVersion: unit.dependencyVersion
            )
        }
        return .accepted
    }

    func noteSubmitted(
        _ unit: StreamControllerMosaicMediaUnitReassembler.CompletedUnit,
        presentationTime: CMTime
    ) {
        lock.lock()
        defer { lock.unlock() }

        resetForPlanEpochIfNeeded(unit.tilePlanEpoch)
        pendingTileVersionsByDecodeKey[PendingDecodeKey(
            mediaUnitIndex: unit.mediaUnitIndex,
            mediaEpoch: presentationTime.value
        )] = unit.tileVersion
    }

    func noteDecoded(mediaUnitIndex: UInt16, presentationTime: CMTime) {
        lock.lock()
        defer { lock.unlock() }

        let key = PendingDecodeKey(
            mediaUnitIndex: mediaUnitIndex,
            mediaEpoch: presentationTime.value
        )
        guard let tileVersion = pendingTileVersionsByDecodeKey.removeValue(forKey: key) else {
            return
        }
        retainedTileVersionsByMediaUnitIndex[mediaUnitIndex] = tileVersion
    }

    func reset() {
        lock.lock()
        activePlanEpoch = nil
        retainedTileVersionsByMediaUnitIndex.removeAll(keepingCapacity: false)
        pendingTileVersionsByDecodeKey.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    func reset(mediaUnitIndex: UInt16) {
        lock.lock()
        retainedTileVersionsByMediaUnitIndex.removeValue(forKey: mediaUnitIndex)
        pendingTileVersionsByDecodeKey = pendingTileVersionsByDecodeKey.filter { element in
            element.key.mediaUnitIndex != mediaUnitIndex
        }
        lock.unlock()
    }

    private func resetForPlanEpochIfNeeded(_ planEpoch: UInt32) {
        guard activePlanEpoch != planEpoch else { return }
        activePlanEpoch = planEpoch
        retainedTileVersionsByMediaUnitIndex.removeAll(keepingCapacity: false)
        pendingTileVersionsByDecodeKey.removeAll(keepingCapacity: false)
    }
}

actor StreamControllerMosaicClientPipeline {
    enum RecoveryTrigger: String, Sendable {
        case dependencyMissing = "dependency-missing"
        case dependencyMismatch = "dependency-mismatch"
        case decodeErrorThreshold = "decode-error-threshold"
        case decodeSubmissionFailure = "decode-submission-failure"
    }

    enum ProcessResult: Equatable, Sendable {
        case submitted
        case dropped
        case needsRecovery(RecoveryTrigger)
    }

    private struct DecoderSignature: Hashable {
        let planEpoch: UInt32
        let mediaUnitIndex: UInt16
        let unitID: MirageMosaicCodecUnitID
        let encodedSize: MiragePixelSize
        let codec: MirageVideoCodec
    }

    private struct DecoderEntry {
        let signature: DecoderSignature
        let decoder: VideoDecoder
    }

    private let streamID: StreamID
    private let presenter: StreamControllerMosaicRetainedFramePresenter
    private let dependencyState = StreamControllerMosaicDependencyState()
    private let onRecoveryNeeded: (@Sendable (StreamID, RecoveryTrigger) -> Void)?
    private var decodersByMediaUnitIndex: [UInt16: DecoderEntry] = [:]

    init(
        streamID: StreamID,
        onRecoveryNeeded: (@Sendable (StreamID, RecoveryTrigger) -> Void)? = nil
    ) {
        self.streamID = streamID
        self.onRecoveryNeeded = onRecoveryNeeded
        presenter = StreamControllerMosaicRetainedFramePresenter(streamID: streamID)
    }

    func process(
        _ unit: StreamControllerMosaicMediaUnitReassembler.CompletedUnit,
        plan: MirageMosaicTilePlan
    ) async -> ProcessResult {
        guard unit.streamID == streamID,
              unit.tilePlanEpoch == plan.epoch,
              Int(unit.mediaUnitIndex) < plan.codecUnits.count else {
            return .dropped
        }

        let codecUnit = plan.codecUnits[Int(unit.mediaUnitIndex)]
        guard !codecUnit.encodedSize.isEmpty,
              !codecUnit.presentationRect.size.isEmpty else {
            return .dropped
        }

        switch dependencyState.validate(unit) {
        case .accepted:
            break
        case let .stale(retainedVersion, tileVersion):
            MirageLogger.client(
                "Mosaic stale unit dropped for stream \(streamID) unit=\(unit.mediaUnitIndex) " +
                    "epoch=\(unit.mediaEpoch) retained=\(retainedVersion) tileVersion=\(tileVersion)"
            )
            return .dropped
        case .missingDependency:
            MirageLogger.client(
                "Mosaic dependency missing for stream \(streamID) unit=\(unit.mediaUnitIndex) " +
                    "epoch=\(unit.mediaEpoch) tileVersion=\(unit.tileVersion) dependency=\(unit.dependencyVersion)"
            )
            onRecoveryNeeded?(streamID, .dependencyMissing)
            return .needsRecovery(.dependencyMissing)
        case let .dependencyMismatch(retainedVersion, expectedVersion):
            MirageLogger.client(
                "Mosaic dependency mismatch for stream \(streamID) unit=\(unit.mediaUnitIndex) " +
                    "epoch=\(unit.mediaEpoch) tileVersion=\(unit.tileVersion) " +
                    "retained=\(retainedVersion) expected=\(expectedVersion)"
            )
            dependencyState.reset(mediaUnitIndex: unit.mediaUnitIndex)
            onRecoveryNeeded?(streamID, .dependencyMismatch)
            return .needsRecovery(.dependencyMismatch)
        }

        let decoder = await decoder(
            for: unit.mediaUnitIndex,
            codecUnit: codecUnit,
            plan: plan
        )
        let presentationTime = CMTime(value: Int64(unit.mediaEpoch), timescale: 60)
        do {
            try await decoder.decodeFrame(
                unit.payload,
                presentationTime: presentationTime,
                isKeyframe: unit.isKeyframe,
                frameNumber: unit.unitFrameNumber,
                contentRect: Self.cgRect(from: codecUnit.presentationRect)
            )
        } catch {
            MirageLogger.error(.decoder, error: error, message: "Mosaic unit decode error: ")
            dependencyState.reset(mediaUnitIndex: unit.mediaUnitIndex)
            onRecoveryNeeded?(streamID, .decodeSubmissionFailure)
            return .needsRecovery(.decodeSubmissionFailure)
        }
        dependencyState.noteSubmitted(unit, presentationTime: presentationTime)
        return .submitted
    }

    func reset() async {
        let decoders = decodersByMediaUnitIndex.values.map(\.decoder)
        decodersByMediaUnitIndex.removeAll(keepingCapacity: false)
        presenter.reset()
        dependencyState.reset()
        for decoder in decoders {
            await decoder.stopDecoding()
        }
    }

    private func decoder(
        for mediaUnitIndex: UInt16,
        codecUnit: MirageMosaicCodecUnitDescriptor,
        plan: MirageMosaicTilePlan
    ) async -> VideoDecoder {
        let signature = DecoderSignature(
            planEpoch: plan.epoch,
            mediaUnitIndex: mediaUnitIndex,
            unitID: codecUnit.id,
            encodedSize: codecUnit.encodedSize,
            codec: codecUnit.codec
        )
        if let entry = decodersByMediaUnitIndex[mediaUnitIndex],
           entry.signature == signature {
            return entry.decoder
        }

        if let previous = decodersByMediaUnitIndex[mediaUnitIndex]?.decoder {
            await previous.stopDecoding()
        }

        let decoder = VideoDecoder()
        await decoder.setCodec(
            codecUnit.codec,
            streamDimensions: (
                width: codecUnit.encodedSize.width,
                height: codecUnit.encodedSize.height
            )
        )
        await decoder.setErrorThresholdHandler { [dependencyState, onRecoveryNeeded, streamID, mediaUnitIndex] in
            dependencyState.reset(mediaUnitIndex: mediaUnitIndex)
            onRecoveryNeeded?(streamID, .decodeErrorThreshold)
        }
        await decoder.startDecoding { [dependencyState, presenter] pixelBuffer, presentationTime, _ in
            dependencyState.noteDecoded(
                mediaUnitIndex: mediaUnitIndex,
                presentationTime: presentationTime
            )
            presenter.enqueueDecodedUnit(
                pixelBuffer: pixelBuffer,
                presentationTime: presentationTime,
                mediaUnitIndex: mediaUnitIndex,
                plan: plan,
                presentationRect: codecUnit.presentationRect
            )
        }
        decodersByMediaUnitIndex[mediaUnitIndex] = DecoderEntry(
            signature: signature,
            decoder: decoder
        )
        return decoder
    }

    private static func cgRect(from rect: MiragePixelRect) -> CGRect {
        CGRect(
            x: CGFloat(rect.x),
            y: CGFloat(rect.y),
            width: CGFloat(rect.width),
            height: CGFloat(rect.height)
        )
    }
}
