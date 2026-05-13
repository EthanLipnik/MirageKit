//
//  VideoEncoder+PropertyApplication.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//
//  VideoToolbox property support and hardware-status helpers.
//

import CoreMedia
import Foundation
import VideoToolbox

#if os(macOS)
extension VideoEncoder {
    func loadSupportedProperties(_ session: VTCompressionSession) {
        var propertyDictionary: CFDictionary?
        let status = VTSessionCopySupportedPropertyDictionary(
            session,
            supportedPropertyDictionaryOut: &propertyDictionary
        )
        didQuerySupportedProperties = (status == noErr)
        guard status == noErr, let dict = propertyDictionary as? [CFString: Any] else {
            supportedPropertyKeys = []
            loggedUnsupportedKeys = []
            MirageLogger.encoder("Encoder property support lookup failed: \(status)")
            return
        }
        supportedPropertyKeys = Set(dict.keys)
        loggedUnsupportedKeys = []
    }

    func refreshHardwareStatusIfNeeded(reason: String) {
        guard hardwareStatusRefreshAttempts < maxHardwareStatusRefreshAttempts else { return }
        guard usingHardwareEncoder == nil || encoderGPURegistryID == nil else { return }
        guard let session = compressionSession else { return }
        logHardwareStatus(session, reason: reason)
    }

    func logHardwareStatus(_ session: VTCompressionSession, reason: String) {
        hardwareStatusRefreshAttempts += 1

        var hw: Unmanaged<CFTypeRef>?
        let hwStatus = VTSessionCopyProperty(
            session,
            key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
            allocator: kCFAllocatorDefault,
            valueOut: &hw
        )
        if hwStatus == noErr,
           let value = hw?.takeRetainedValue(),
           let boolValue = value as? Bool {
            usingHardwareEncoder = boolValue
        }

        var gpu: Unmanaged<CFTypeRef>?
        let gpuStatus = VTSessionCopyProperty(
            session,
            key: kVTCompressionPropertyKey_UsingGPURegistryID,
            allocator: kCFAllocatorDefault,
            valueOut: &gpu
        )
        if gpuStatus == noErr,
           let value = gpu?.takeRetainedValue(),
           let registry = value as? NSNumber {
            encoderGPURegistryID = registry.uint64Value
        }

        let usingHardwareText = if let usingHardwareEncoder {
            String(usingHardwareEncoder)
        } else {
            "unknown(status=\(hwStatus))"
        }
        let gpuText = if let encoderGPURegistryID {
            String(encoderGPURegistryID)
        } else if gpuStatus == noErr {
            "nil"
        } else {
            "unknown(status=\(gpuStatus))"
        }
        let healthText = if usingHardwareEncoder == true {
            "active"
        } else if usingHardwareEncoder == false {
            "software_fallback"
        } else {
            "unknown"
        }

        MirageLogger.encoder(
            "event=hardware_encoder_status reason=\(reason) usingHardware=\(usingHardwareText) " +
                "status=\(healthText) gpuRegistryID=\(gpuText) requiredBySpec=true"
        )
    }

    func setProperty(_ session: VTCompressionSession, key: CFString, value: CFTypeRef) -> Bool {
        setPropertyOutcome(session, key: key, value: value) == .applied
    }

    func setPropertyOutcome(
        _ session: VTCompressionSession,
        key: CFString,
        value: CFTypeRef
    ) -> PropertyApplyOutcome {
        if didQuerySupportedProperties, !supportedPropertyKeys.contains(key) {
            if !loggedUnsupportedKeys.contains(key) {
                loggedUnsupportedKeys.insert(key)
                MirageLogger.encoder("Encoder property unsupported: \(key)")
            }
            return .unsupported
        }
        let status = VTSessionSetProperty(session, key: key, value: value)
        if Self.unsupportedEncoderPropertyStatuses.contains(status) {
            if !loggedUnsupportedKeys.contains(key) {
                loggedUnsupportedKeys.insert(key)
                MirageLogger.encoder("Encoder property unsupported: \(key) (status \(status))")
            }
            return .unsupported
        }
        guard status == noErr else {
            MirageLogger.error(.encoder, "VTSessionSetProperty \(key) failed: \(status)")
            return .failed
        }
        return .applied
    }

    nonisolated static let unsupportedEncoderPropertyStatuses: Set<OSStatus> = [
        -12900,
    ]

    func setPropertyTracked(
        _ session: VTCompressionSession,
        key: CFString,
        value: CFTypeRef,
        propertyName: String,
        status: inout SessionPolicyStatus
    ) -> Bool {
        let outcome = setPropertyOutcome(session, key: key, value: value)
        status.record(propertyName, outcome: outcome)
        return outcome == .applied
    }

    var maximizePowerEfficiencyValue: CFTypeRef {
        maximizePowerEfficiencyEnabled ? kCFBooleanTrue : kCFBooleanFalse
    }

    func applyMaximizePowerEfficiency(_ session: VTCompressionSession) -> Bool {
        setProperty(
            session,
            key: kVTCompressionPropertyKey_MaximizePowerEfficiency,
            value: maximizePowerEfficiencyValue
        )
    }

    func applyMaximizePowerEfficiencyTracked(
        _ session: VTCompressionSession,
        status: inout SessionPolicyStatus
    ) -> Bool {
        setPropertyTracked(
            session,
            key: kVTCompressionPropertyKey_MaximizePowerEfficiency,
            value: maximizePowerEfficiencyValue,
            propertyName: "maximizePowerEfficiency",
            status: &status
        )
    }

    func hevcProfileName(for profile: CFString) -> String {
        if CFEqual(profile, kVTProfileLevel_HEVC_Main42210_AutoLevel) {
            return "HEVC Main42210 (4:2:2)"
        }
        if CFEqual(profile, kVTProfileLevel_HEVC_Main10_AutoLevel) {
            return "HEVC Main10 (4:2:0)"
        }
        if CFEqual(profile, kVTProfileLevel_HEVC_Main_AutoLevel) {
            return "HEVC Main (4:2:0)"
        }
        return profile as String
    }
}

#endif
