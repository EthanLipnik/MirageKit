//
//  HEVCEncoder+UltraProbe.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/12/26.
//

import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import MirageKit

#if os(macOS)
import ScreenCaptureKit

package struct HEVCEncoderUltraProbeResult: Sendable {
    package let captureAcceptsXF44: Bool
    package let encoderSessionCreated: Bool
    package let encodedChromaSampling: MirageStreamChromaSampling?
    package let usingHardwareEncoder: Bool?

    package var supportsUltra444: Bool {
        captureAcceptsXF44 &&
            encoderSessionCreated &&
            encodedChromaSampling == .yuv444 &&
            usingHardwareEncoder != false
    }
}

extension HEVCEncoder {
    package static func probeStrictUltra444Support() -> HEVCEncoderUltraProbeResult {
        let captureAcceptsXF44 = captureAcceptsXF44()
        guard captureAcceptsXF44 else {
            return HEVCEncoderUltraProbeResult(
                captureAcceptsXF44: false,
                encoderSessionCreated: false,
                encodedChromaSampling: nil,
                usingHardwareEncoder: nil
            )
        }

        let width = 128
        let height = 72
        let pixelFormat = kCVPixelFormatType_444YpCbCr10BiPlanarFullRange
        let imageBufferAttributes: CFDictionary = [
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ] as CFDictionary

        var session: VTCompressionSession?
        let sessionStatus = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: HEVCEncoder.encoderSpecification(
                for: .standard,
                latencyMode: .auto,
                width: width,
                height: height,
                streamKind: .window
            ) as CFDictionary,
            imageBufferAttributes: imageBufferAttributes,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )

        guard sessionStatus == noErr, let session else {
            return HEVCEncoderUltraProbeResult(
                captureAcceptsXF44: captureAcceptsXF44,
                encoderSessionCreated: false,
                encodedChromaSampling: nil,
                usingHardwareEncoder: nil
            )
        }

        defer {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }

        setProbeColorProperties(on: session)
        _ = VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_RealTime,
            value: kCFBooleanTrue
        )
        _ = VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_AllowFrameReordering,
            value: kCFBooleanFalse
        )
        _ = VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_MaximizePowerEfficiency,
            value: kCFBooleanFalse
        )
        VTCompressionSessionPrepareToEncodeFrames(session)

        guard let pixelBuffer = makeProbePixelBuffer(
            width: width,
            height: height,
            pixelFormat: pixelFormat
        ) else {
            return HEVCEncoderUltraProbeResult(
                captureAcceptsXF44: captureAcceptsXF44,
                encoderSessionCreated: true,
                encodedChromaSampling: nil,
                usingHardwareEncoder: hardwareEncoderStatus(session)
            )
        }

        let semaphore = DispatchSemaphore(value: 0)
        let callbackState = Locked<MirageStreamChromaSampling?>(nil)

        let encodeStatus = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: .zero,
            duration: CMTime(value: 1, timescale: 60),
            frameProperties: [
                kVTEncodeFrameOptionKey_ForceKeyFrame: true,
            ] as CFDictionary,
            infoFlagsOut: nil
        ) { status, infoFlags, sampleBuffer in
            defer { semaphore.signal() }
            guard status == noErr,
                  !infoFlags.contains(.frameDropped),
                  let sampleBuffer,
                  let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
                return
            }
            callbackState.withLock { state in
                state = HEVCEncoder.chromaSampling(from: formatDescription)
            }
        }

        if encodeStatus == noErr {
            _ = semaphore.wait(timeout: .now() + .milliseconds(750))
        }

        return HEVCEncoderUltraProbeResult(
            captureAcceptsXF44: captureAcceptsXF44,
            encoderSessionCreated: true,
            encodedChromaSampling: callbackState.withLock { $0 },
            usingHardwareEncoder: hardwareEncoderStatus(session)
        )
    }

    private static func captureAcceptsXF44() -> Bool {
        let configuration = SCStreamConfiguration()
        configuration.pixelFormat = kCVPixelFormatType_444YpCbCr10BiPlanarFullRange
        return configuration.pixelFormat == kCVPixelFormatType_444YpCbCr10BiPlanarFullRange
    }

    private static func hardwareEncoderStatus(_ session: VTCompressionSession) -> Bool? {
        var value: CFTypeRef?
        let status = VTSessionCopyProperty(
            session,
            key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
            allocator: kCFAllocatorDefault,
            valueOut: &value
        )
        guard status == noErr else { return nil }
        return value as? Bool
    }

    private static func setProbeColorProperties(on session: VTCompressionSession) {
        let properties: [(CFString, CFTypeRef)] = [
            (kVTCompressionPropertyKey_ColorPrimaries, kCMFormatDescriptionColorPrimaries_P3_D65 as CFString),
            (kVTCompressionPropertyKey_TransferFunction, kCMFormatDescriptionTransferFunction_sRGB as CFString),
            (kVTCompressionPropertyKey_YCbCrMatrix, kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as CFString),
        ]
        for (key, value) in properties {
            _ = VTSessionSetProperty(session, key: key, value: value)
        }
    }

    private static func makeProbePixelBuffer(
        width: Int,
        height: Int,
        pixelFormat: OSType
    ) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            pixelFormat,
            [
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ] as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if CVPixelBufferIsPlanar(pixelBuffer) {
            let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)
            for plane in 0 ..< planeCount {
                guard let baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) else { continue }
                let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
                let planeHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
                memset(baseAddress, 0x80, bytesPerRow * planeHeight)
            }
        } else if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            memset(baseAddress, 0x80, bytesPerRow * height)
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        return pixelBuffer
    }
}
#endif
