//
//  HEVCEncoder+Adjustments.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  HEVC encoder extensions.
//

import CoreMedia
import Foundation
import VideoToolbox
import MirageKit

#if os(macOS)
import ScreenCaptureKit

extension HEVCEncoder {
    func updateQuality(_ quality: Float) {
        guard let session = compressionSession else { return }
        baseQuality = min(quality, compressionQualityCeiling)
        guard !qualityOverrideActive else { return }
        applyQualitySettings(session, quality: baseQuality, log: false)
    }

    func prepareForKeyframe(quality: Float) {
        guard let session = compressionSession else { return }
        let clamped = max(0.02, min(compressionQualityCeiling, quality))
        guard clamped < baseQuality else { return }
        qualityOverrideActive = true
        applyQualitySettings(session, quality: clamped, log: false)
    }

    func restoreBaseQualityIfNeeded() {
        guard qualityOverrideActive, let session = compressionSession else { return }
        qualityOverrideActive = false
        applyQualitySettings(session, quality: baseQuality, log: false)
    }

    func updateFrameRate(_ fps: Int) {
        let clamped = max(1, fps)
        configuration = configuration.withTargetFrameRate(clamped)
        guard let session = compressionSession else { return }
        setProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: clamped as CFNumber)
        let intervalSeconds = max(1.0, Double(configuration.keyFrameInterval) / Double(clamped))
        setProperty(
            session,
            key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
            value: intervalSeconds as CFNumber
        )
        applyBitrateSettingsToActiveSession()
    }

    func updateInFlightLimit(_ limit: Int) {
        let clamped = max(1, limit)
        encoderInFlightLock.lock()
        encoderInFlightLimit = clamped
        encoderInFlightLock.unlock()
    }

    func updateDimensions(width: Int, height: Int) async throws {
        MirageLogger.encoder("Updating dimensions to \(width)x\(height)")

        // Gate new frames from entering during update to prevent deadlock
        isUpdatingDimensions = true
        defer { isUpdatingDimensions = false }

        // Increment session version BEFORE completing old frames
        // This ensures any in-flight callbacks from old session will be discarded
        sessionVersion += 1
        MirageLogger.encoder("Session version incremented to \(sessionVersion)")
        resetEncoderSlots()

        // Complete and invalidate the old session
        if let session = compressionSession {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
            compressionSession = nil
        }

        // Reset frame number to force keyframe on first frame of new session
        frameNumber = 0
        forceNextKeyframe = true

        // Create a new session with the new dimensions
        try createSession(width: width, height: height)
        MirageLogger.encoder("Session recreated with new dimensions")
    }

    func updateConfiguration(_ newConfiguration: MirageEncoderConfiguration) async throws {
        configuration = newConfiguration
        activePixelFormat = newConfiguration.pixelFormat
        didLogPixelFormat = false
        baseQuality = min(newConfiguration.frameQuality, compressionQualityCeiling)
        qualityOverrideActive = false
        sessionVersion += 1
        resetEncoderSlots()

        guard currentWidth > 0, currentHeight > 0 else { return }

        if let session = compressionSession {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
            compressionSession = nil
        }

        frameNumber = 0
        forceNextKeyframe = true

        try createSession(width: currentWidth, height: currentHeight)
        MirageLogger
            .encoder(
                "Encoder configuration updated: format=\(newConfiguration.pixelFormat.displayName), " +
                    "color=\(newConfiguration.colorSpace.displayName), bitrate=\(newConfiguration.bitrate ?? 0)"
            )
    }

    func updateBitrate(_ bitrate: Int?) {
        configuration = configuration.withOverrides(bitrate: bitrate)
        applyBitrateSettingsToActiveSession()
    }

    func forceKeyframe() {
        MirageLogger.encoder("Keyframe requested")
        forceNextKeyframe = true
    }

    func resetFrameNumber() {
        frameNumber = 0
    }

    func getActivePixelFormat() -> MiragePixelFormat {
        activePixelFormat
    }

    func getAverageEncodeTimeMs() -> Double {
        performanceTracker.averageMs()
    }

    func runtimeValidationSnapshot() -> RuntimeValidationSnapshot {
        let profileName = activeProfileLevel.map(hevcProfileName(for:))
        let colorPrimaries = sessionStringProperty(kVTCompressionPropertyKey_ColorPrimaries)
        let transferFunction = sessionStringProperty(kVTCompressionPropertyKey_TransferFunction)
        let yCbCrMatrix = sessionStringProperty(kVTCompressionPropertyKey_YCbCrMatrix)

        let usesMain10Profile = {
            guard let activeProfileLevel else { return false }
            return CFEqual(activeProfileLevel, kVTProfileLevel_HEVC_Main10_AutoLevel) ||
                CFEqual(activeProfileLevel, kVTProfileLevel_HEVC_Main42210_AutoLevel)
        }()

        let usesDisplayP3Tags = {
            guard let colorPrimaries,
                  let transferFunction,
                  let yCbCrMatrix else { return false }
            return colorPrimaries == (kCMFormatDescriptionColorPrimaries_P3_D65 as String) &&
                transferFunction == (kCMFormatDescriptionTransferFunction_sRGB as String) &&
                yCbCrMatrix == (kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String)
        }()

        let validated = activePixelFormat == .p010 && usesMain10Profile && usesDisplayP3Tags
        return RuntimeValidationSnapshot(
            pixelFormat: activePixelFormat,
            profileName: profileName,
            colorPrimaries: colorPrimaries,
            transferFunction: transferFunction,
            yCbCrMatrix: yCbCrMatrix,
            tenBitDisplayP3Validated: validated
        )
    }

    private func sessionStringProperty(_ key: CFString) -> String? {
        guard let session = compressionSession else { return nil }
        var value: CFTypeRef?
        let status = VTSessionCopyProperty(
            session,
            key: key,
            allocator: kCFAllocatorDefault,
            valueOut: &value
        )
        guard status == noErr, let value else { return nil }
        return value as? String
    }

    func flush() {
        guard let session = compressionSession else { return }

        // Complete all pending frames - this blocks until the encoder pipeline is clear
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)

        // Reset frame counter and force keyframe on next encode
        frameNumber = 0
        forceNextKeyframe = true

        MirageLogger.encoder("Encoder flushed - next frame will be keyframe")
    }

    func reset() async throws {
        guard let session = compressionSession else { return }
        guard currentWidth > 0, currentHeight > 0 else { return }

        MirageLogger.encoder("Resetting encoder session (\(currentWidth)x\(currentHeight))")
        sessionVersion += 1
        let staleSlots = encoderInFlightSnapshot()
        if staleSlots > 0 {
            MirageLogger.encoder("Clearing \(staleSlots) stale encoder slots")
        }
        resetEncoderSlots()

        // Invalidate the stuck session
        VTCompressionSessionInvalidate(session)
        compressionSession = nil

        // Reset frame number and force keyframe
        frameNumber = 0
        forceNextKeyframe = true

        // Create a fresh session with stored dimensions
        try createSession(width: currentWidth, height: currentHeight)

        MirageLogger.encoder("Encoder session reset complete")
    }
}

#endif
