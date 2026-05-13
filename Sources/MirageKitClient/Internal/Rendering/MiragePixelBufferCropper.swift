//
//  MiragePixelBufferCropper.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/4/26.
//
//  CoreVideo-backed source cropping for logical app-atlas presentation.
//

import CoreGraphics
import CoreVideo
import Foundation
import VideoToolbox

struct MiragePixelBufferCropResult {
    let pixelBuffer: CVPixelBuffer
    let contentRect: CGRect
}

final class MiragePixelBufferCropper: @unchecked Sendable {
    private struct OutputPoolKey: Equatable {
        let width: Int
        let height: Int
        let pixelFormat: OSType
    }

    private struct AttachmentSnapshot {
        let value: CFTypeRef?
        let mode: CVAttachmentMode
    }

    private var outputPoolKey: OutputPoolKey?
    private var outputPool: CVPixelBufferPool?
    private var transferSession: VTPixelTransferSession?

    deinit {
        if let transferSession {
            VTPixelTransferSessionInvalidate(transferSession)
        }
    }

    func crop(_ source: CVPixelBuffer, to contentRect: CGRect) -> MiragePixelBufferCropResult? {
        let sourceWidth = CVPixelBufferGetWidth(source)
        let sourceHeight = CVPixelBufferGetHeight(source)
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }

        let fullRect = CGRect(
            x: 0,
            y: 0,
            width: CGFloat(sourceWidth),
            height: CGFloat(sourceHeight)
        )
        guard let cropRect = Self.normalizedCropRect(contentRect, in: fullRect) else {
            return MiragePixelBufferCropResult(
                pixelBuffer: source,
                contentRect: fullRect
            )
        }

        guard cropRect != fullRect else {
            return MiragePixelBufferCropResult(
                pixelBuffer: source,
                contentRect: fullRect
            )
        }

        let cropWidth = Int(cropRect.width)
        let cropHeight = Int(cropRect.height)
        let pixelFormat = CVPixelBufferGetPixelFormatType(source)
        guard let destination = makeOutputBuffer(width: cropWidth, height: cropHeight, pixelFormat: pixelFormat) else {
            return nil
        }

        if copyBGRA(source, to: destination, sourceRect: cropRect) ||
            transfer(source, to: destination, sourceRect: cropRect) {
            return MiragePixelBufferCropResult(
                pixelBuffer: destination,
                contentRect: CGRect(
                    x: 0,
                    y: 0,
                    width: CGFloat(cropWidth),
                    height: CGFloat(cropHeight)
                )
            )
        }

        return nil
    }

    private static func normalizedCropRect(_ contentRect: CGRect, in fullRect: CGRect) -> CGRect? {
        let candidate = contentRect.standardized
        guard candidate.origin.x.isFinite,
              candidate.origin.y.isFinite,
              candidate.width.isFinite,
              candidate.height.isFinite,
              candidate.width > 0,
              candidate.height > 0 else {
            return nil
        }

        let integral = candidate.integral
        guard integral.width > 0,
              integral.height > 0,
              fullRect.contains(integral) else {
            return nil
        }
        return integral
    }

    private func makeOutputBuffer(width: Int, height: Int, pixelFormat: OSType) -> CVPixelBuffer? {
        let key = OutputPoolKey(width: width, height: height, pixelFormat: pixelFormat)
        if outputPoolKey != key || outputPool == nil {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: pixelFormat,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferMetalCompatibilityKey: true,
            ]
            var pool: CVPixelBufferPool?
            let status = CVPixelBufferPoolCreate(
                kCFAllocatorDefault,
                nil,
                attributes as CFDictionary,
                &pool
            )
            guard status == kCVReturnSuccess, let pool else { return nil }
            outputPoolKey = key
            outputPool = pool
        }

        guard let outputPool else { return nil }
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault,
            outputPool,
            &buffer
        )
        guard status == kCVReturnSuccess else { return nil }
        return buffer
    }

    private func transfer(
        _ source: CVPixelBuffer,
        to destination: CVPixelBuffer,
        sourceRect: CGRect
    ) -> Bool {
        guard let session = pixelTransferSession() else { return false }

        let destinationSize = CGSize(
            width: CGFloat(CVPixelBufferGetWidth(destination)),
            height: CGFloat(CVPixelBufferGetHeight(destination))
        )
        let destinationRect = CGRect(origin: .zero, size: destinationSize)
        let destinationCleanAperture = Self.cleanApertureDictionary(
            rect: destinationRect,
            imageSize: destinationSize
        )

        guard VTSessionSetProperty(
            session,
            key: kVTPixelTransferPropertyKey_ScalingMode,
            value: kVTScalingMode_CropSourceToCleanAperture
        ) == noErr,
            VTSessionSetProperty(
                session,
                key: kVTPixelTransferPropertyKey_DestinationCleanAperture,
                value: destinationCleanAperture
            ) == noErr else {
            return false
        }

        let sourceSize = CGSize(
            width: CGFloat(CVPixelBufferGetWidth(source)),
            height: CGFloat(CVPixelBufferGetHeight(source))
        )
        let sourceCleanAperture = Self.cleanApertureDictionary(
            rect: sourceRect,
            imageSize: sourceSize
        )
        let priorCleanAperture = Self.attachmentSnapshot(
            source,
            key: kCVImageBufferCleanApertureKey
        )
        CVBufferSetAttachment(
            source,
            kCVImageBufferCleanApertureKey,
            sourceCleanAperture,
            .shouldPropagate
        )
        defer {
            Self.restoreAttachment(
                priorCleanAperture,
                on: source,
                key: kCVImageBufferCleanApertureKey
            )
        }

        let status = VTPixelTransferSessionTransferImage(
            session,
            from: source,
            to: destination
        )
        return status == noErr
    }

    private func pixelTransferSession() -> VTPixelTransferSession? {
        if let transferSession { return transferSession }

        var session: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(
            allocator: kCFAllocatorDefault,
            pixelTransferSessionOut: &session
        ) == noErr,
              let session else {
            return nil
        }

        transferSession = session
        return session
    }

    private func copyBGRA(
        _ source: CVPixelBuffer,
        to destination: CVPixelBuffer,
        sourceRect: CGRect
    ) -> Bool {
        guard CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetPixelFormatType(destination) == kCVPixelFormatType_32BGRA else {
            return false
        }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }

        guard let sourceBase = CVPixelBufferGetBaseAddress(source),
              let destinationBase = CVPixelBufferGetBaseAddress(destination) else {
            return false
        }

        let sourceX = Int(sourceRect.minX)
        let sourceY = Int(sourceRect.minY)
        let width = min(Int(sourceRect.width), CVPixelBufferGetWidth(destination))
        let height = min(Int(sourceRect.height), CVPixelBufferGetHeight(destination))
        let bytesPerPixel = 4
        let copyBytesPerRow = width * bytesPerPixel
        let sourceBytesPerRow = CVPixelBufferGetBytesPerRow(source)
        let destinationBytesPerRow = CVPixelBufferGetBytesPerRow(destination)

        for row in 0 ..< height {
            let sourceOffset = (sourceY + row) * sourceBytesPerRow + sourceX * bytesPerPixel
            let destinationOffset = row * destinationBytesPerRow
            memcpy(
                destinationBase.advanced(by: destinationOffset),
                sourceBase.advanced(by: sourceOffset),
                copyBytesPerRow
            )
        }

        CVBufferPropagateAttachments(source, destination)
        let destinationSize = CGSize(
            width: CGFloat(CVPixelBufferGetWidth(destination)),
            height: CGFloat(CVPixelBufferGetHeight(destination))
        )
        CVBufferSetAttachment(
            destination,
            kCVImageBufferCleanApertureKey,
            Self.cleanApertureDictionary(
                rect: CGRect(origin: .zero, size: destinationSize),
                imageSize: destinationSize
            ),
            .shouldPropagate
        )
        return true
    }

    private static func cleanApertureDictionary(rect: CGRect, imageSize: CGSize) -> CFDictionary {
        let horizontalOffset = rect.midX - imageSize.width * 0.5
        let verticalOffset = rect.midY - imageSize.height * 0.5
        let values: [CFString: Any] = [
            kCVImageBufferCleanApertureWidthKey: rect.width,
            kCVImageBufferCleanApertureHeightKey: rect.height,
            kCVImageBufferCleanApertureHorizontalOffsetKey: horizontalOffset,
            kCVImageBufferCleanApertureVerticalOffsetKey: verticalOffset,
        ]
        return values as CFDictionary
    }

    private static func attachmentSnapshot(_ buffer: CVBuffer, key: CFString) -> AttachmentSnapshot {
        var mode = CVAttachmentMode.shouldNotPropagate
        let value = CVBufferCopyAttachment(buffer, key, &mode)
        return AttachmentSnapshot(value: value, mode: mode)
    }

    private static func restoreAttachment(
        _ snapshot: AttachmentSnapshot,
        on buffer: CVBuffer,
        key: CFString
    ) {
        if let value = snapshot.value {
            CVBufferSetAttachment(buffer, key, value, snapshot.mode)
        } else {
            CVBufferRemoveAttachment(buffer, key)
        }
    }
}
