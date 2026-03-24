//
//  HostAudioMuteController.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/9/26.
//
//  Host output mute lifecycle while audio streaming is active.
//

import Foundation
import MirageKit

#if os(macOS)
import CoreAudio

@MainActor
final class HostAudioMuteController {
    private var originalMuteStateByDeviceID: [AudioDeviceID: Bool] = [:]
    private var unsupportedMuteDeviceIDs: Set<AudioDeviceID> = []
    private let listenerQueue = DispatchQueue(label: "com.mirage.host.audio-mute-listener")
    private var defaultOutputListener: AudioObjectPropertyListenerBlock?
    private var muteRequested = false

    func setMuted(_ shouldMute: Bool) {
        muteRequested = shouldMute
        if shouldMute {
            ensureDefaultOutputListener()
            muteCurrentOutputDeviceIfNeeded()
        } else {
            removeDefaultOutputListener()
            restoreOriginalMuteState()
        }
    }

    private func ensureDefaultOutputListener() {
        guard defaultOutputListener == nil else { return }

        var address = defaultOutputDeviceAddress
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self, self.muteRequested else { return }
                self.muteCurrentOutputDeviceIfNeeded()
            }
        }

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            listenerQueue,
            block
        )
        guard status == noErr else {
            MirageLogger.error(.host, "Failed to install audio output listener: OSStatus \(status)")
            return
        }

        defaultOutputListener = block
    }

    private func removeDefaultOutputListener() {
        guard let block = defaultOutputListener else { return }

        var address = defaultOutputDeviceAddress
        let status = AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            listenerQueue,
            block
        )
        if status != noErr {
            MirageLogger.error(.host, "Failed to remove audio output listener: OSStatus \(status)")
        }

        defaultOutputListener = nil
    }

    private func muteCurrentOutputDeviceIfNeeded() {
        guard let deviceID = defaultOutputDeviceID() else { return }
        guard let currentMute = readMuteState(for: deviceID) else {
            logUnsupportedMuteDeviceIfNeeded(deviceID)
            return
        }

        if originalMuteStateByDeviceID[deviceID] == nil {
            originalMuteStateByDeviceID[deviceID] = currentMute
        }

        guard !currentMute else { return }
        guard writeMuteState(true, for: deviceID) else {
            logUnsupportedMuteDeviceIfNeeded(deviceID)
            return
        }
    }

    private func restoreOriginalMuteState() {
        for (deviceID, originalMuteState) in originalMuteStateByDeviceID {
            writeMuteState(originalMuteState, for: deviceID)
        }
        originalMuteStateByDeviceID.removeAll()
    }

    private func logUnsupportedMuteDeviceIfNeeded(_ deviceID: AudioDeviceID) {
        guard unsupportedMuteDeviceIDs.insert(deviceID).inserted else { return }
        MirageLogger.host("Default output device \(deviceID) does not expose a writable mute property")
    }

    private func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = defaultOutputDeviceAddress
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr else {
            MirageLogger.error(.host, "Failed to read default output device: OSStatus \(status)")
            return nil
        }
        guard deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private func readMuteState(for deviceID: AudioDeviceID) -> Bool? {
        var address = outputMuteAddress
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }

        var muteValue: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &muteValue
        )
        guard status == noErr else {
            MirageLogger.error(.host, "Failed to read device mute state: OSStatus \(status)")
            return nil
        }
        return muteValue != 0
    }

    @discardableResult
    private func writeMuteState(_ muted: Bool, for deviceID: AudioDeviceID) -> Bool {
        var address = outputMuteAddress
        guard AudioObjectHasProperty(deviceID, &address) else { return false }

        var settable = DarwinBoolean(false)
        let settableStatus = AudioObjectIsPropertySettable(deviceID, &address, &settable)
        guard settableStatus == noErr else {
            MirageLogger.error(.host, "Failed to query mute mutability: OSStatus \(settableStatus)")
            return false
        }
        guard settable.boolValue else { return false }

        var value: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            size,
            &value
        )
        guard status == noErr else {
            MirageLogger.error(.host, "Failed to set device mute state: OSStatus \(status)")
            return false
        }
        return true
    }

    private var defaultOutputDeviceAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private var outputMuteAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}

#endif
