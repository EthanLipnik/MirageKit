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
    private let streamID: StreamID
    private let context = CIContext(options: nil)
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let lock = NSLock()
    private var activePlanEpoch: UInt32?
    private var activeLogicalSize = MiragePixelSize(width: 0, height: 0)
    private var retainedImages: [UInt16: CIImage] = [:]

    init(streamID: StreamID) {
        self.streamID = streamID
    }

    func reset() {
        lock.lock()
        activePlanEpoch = nil
        activeLogicalSize = MiragePixelSize(width: 0, height: 0)
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
            retainedImages.removeAll(keepingCapacity: false)
        }
        retainedImages[mediaUnitIndex] = Self.image(
            from: pixelBuffer,
            presentationRect: presentationRect,
            canvasHeight: plan.logicalSize.height
        )
        output = renderRetainedFrameLocked(plan: plan)
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

actor StreamControllerMosaicClientPipeline {
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
    private var decodersByMediaUnitIndex: [UInt16: DecoderEntry] = [:]

    init(streamID: StreamID) {
        self.streamID = streamID
        presenter = StreamControllerMosaicRetainedFramePresenter(streamID: streamID)
    }

    func process(
        _ unit: StreamControllerMosaicMediaUnitReassembler.CompletedUnit,
        plan: MirageMosaicTilePlan
    ) async -> Bool {
        guard unit.streamID == streamID,
              unit.tilePlanEpoch == plan.epoch,
              Int(unit.mediaUnitIndex) < plan.codecUnits.count else {
            return false
        }

        let codecUnit = plan.codecUnits[Int(unit.mediaUnitIndex)]
        guard !codecUnit.encodedSize.isEmpty,
              !codecUnit.presentationRect.size.isEmpty else {
            return false
        }

        let decoder = await decoder(
            for: unit.mediaUnitIndex,
            codecUnit: codecUnit,
            plan: plan
        )
        do {
            try await decoder.decodeFrame(
                unit.payload,
                presentationTime: CMTime(value: Int64(unit.mediaEpoch), timescale: 60),
                isKeyframe: unit.isKeyframe,
                frameNumber: unit.unitFrameNumber,
                contentRect: Self.cgRect(from: codecUnit.presentationRect)
            )
        } catch {
            MirageLogger.error(.decoder, error: error, message: "Mosaic unit decode error: ")
            return false
        }
        return true
    }

    func reset() async {
        let decoders = decodersByMediaUnitIndex.values.map(\.decoder)
        decodersByMediaUnitIndex.removeAll(keepingCapacity: false)
        presenter.reset()
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
        await decoder.startDecoding { [presenter] pixelBuffer, presentationTime, _ in
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
