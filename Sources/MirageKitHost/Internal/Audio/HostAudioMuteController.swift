//
//  HostAudioMuteController.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/9/26.
//
//  Host output mute lifecycle while audio streaming is active.
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
import Foundation

#if os(macOS)
import CoreAudio

final class HostAudioDefaultOutputListenerToken {
    let block: AudioObjectPropertyListenerBlock?
    let queue: DispatchQueue?

    init(block: AudioObjectPropertyListenerBlock?, queue: DispatchQueue? = nil) {
        self.block = block
        self.queue = queue
    }
}

protocol HostAudioDeviceDriving: AnyObject {
    func defaultOutputDeviceID() -> AudioDeviceID?
    func readMuteState(for deviceID: AudioDeviceID) -> Bool?
    func writeMuteState(_ muted: Bool, for deviceID: AudioDeviceID) -> Bool
    func writableVolumeElements(for deviceID: AudioDeviceID) -> [AudioObjectPropertyElement]
    func readVolumeScalar(for deviceID: AudioDeviceID, element: AudioObjectPropertyElement) -> Float?
    func writeVolumeScalar(_ volume: Float, for deviceID: AudioDeviceID, element: AudioObjectPropertyElement) -> Bool
    func addDefaultOutputDeviceChangeListener(
        queue: DispatchQueue,
        handler: @escaping @Sendable () -> Void
    ) -> HostAudioDefaultOutputListenerToken?
    func removeDefaultOutputDeviceChangeListener(_ token: HostAudioDefaultOutputListenerToken)
}

@MainActor
final class HostAudioMuteController {
    private enum AppliedMuteState {
        case mute(original: Bool)
        case volume(originalByElement: [AudioObjectPropertyElement: Float])
    }

    private var appliedMuteStateByDeviceID: [AudioDeviceID: AppliedMuteState] = [:]
    private var unsupportedOutputDeviceIDs: Set<AudioDeviceID> = []
    private let listenerQueue = DispatchQueue(label: "com.mirage.host.audio-mute-listener")
    private var defaultOutputListener: HostAudioDefaultOutputListenerToken?
    private var muteRequested = false
    private let driver: HostAudioDeviceDriving

    init(driver: HostAudioDeviceDriving = CoreAudioHostAudioDeviceDriver()) {
        self.driver = driver
    }

    func setMuted(_ shouldMute: Bool) {
        muteRequested = shouldMute
        if shouldMute {
            ensureDefaultOutputListener()
            muteCurrentOutputDeviceIfNeeded()
        } else {
            removeDefaultOutputListener()
            restoreOriginalOutputState()
        }
    }

    private func ensureDefaultOutputListener() {
        guard defaultOutputListener == nil else { return }
        defaultOutputListener = driver.addDefaultOutputDeviceChangeListener(queue: listenerQueue) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.muteRequested else { return }
                self.muteCurrentOutputDeviceIfNeeded()
            }
        }
    }

    private func removeDefaultOutputListener() {
        guard let token = defaultOutputListener else { return }
        driver.removeDefaultOutputDeviceChangeListener(token)
        defaultOutputListener = nil
    }

    private func muteCurrentOutputDeviceIfNeeded() {
        guard let deviceID = driver.defaultOutputDeviceID() else { return }

        if let appliedState = appliedMuteStateByDeviceID[deviceID] {
            reapplyMutedState(appliedState, deviceID: deviceID)
            return
        }

        if applyWritableMuteIfAvailable(deviceID: deviceID) {
            return
        }

        if applyVolumeFallbackIfAvailable(deviceID: deviceID) {
            return
        }

        logUnsupportedOutputDeviceIfNeeded(deviceID)
    }

    private func applyWritableMuteIfAvailable(deviceID: AudioDeviceID) -> Bool {
        guard let currentMute = driver.readMuteState(for: deviceID) else { return false }
        guard driver.writeMuteState(true, for: deviceID) else { return false }
        appliedMuteStateByDeviceID[deviceID] = .mute(original: currentMute)
        MirageLogger.host("Muted local audio output device \(deviceID) using CoreAudio mute property")
        return true
    }

    private func applyVolumeFallbackIfAvailable(deviceID: AudioDeviceID) -> Bool {
        let elements = driver.writableVolumeElements(for: deviceID)
        guard !elements.isEmpty else { return false }

        var originalByElement: [AudioObjectPropertyElement: Float] = [:]
        for element in elements {
            guard let volume = driver.readVolumeScalar(for: deviceID, element: element) else { continue }
            originalByElement[element] = volume
        }
        guard !originalByElement.isEmpty else { return false }

        var wroteAnyVolume = false
        for element in originalByElement.keys.sorted() {
            wroteAnyVolume = driver.writeVolumeScalar(0, for: deviceID, element: element) || wroteAnyVolume
        }
        guard wroteAnyVolume else { return false }

        appliedMuteStateByDeviceID[deviceID] = .volume(originalByElement: originalByElement)
        MirageLogger.host(
            "Muted local audio output device \(deviceID) using volume fallback " +
                "(elements=\(originalByElement.keys.sorted()))"
        )
        return true
    }

    private func reapplyMutedState(_ state: AppliedMuteState, deviceID: AudioDeviceID) {
        switch state {
        case .mute:
            _ = driver.writeMuteState(true, for: deviceID)
        case let .volume(originalByElement):
            for element in originalByElement.keys.sorted() {
                _ = driver.writeVolumeScalar(0, for: deviceID, element: element)
            }
        }
    }

    private func restoreOriginalOutputState() {
        for (deviceID, state) in appliedMuteStateByDeviceID {
            switch state {
            case let .mute(original):
                _ = driver.writeMuteState(original, for: deviceID)
            case let .volume(originalByElement):
                for element in originalByElement.keys.sorted() {
                    guard let volume = originalByElement[element] else { continue }
                    _ = driver.writeVolumeScalar(volume, for: deviceID, element: element)
                }
            }
        }
        appliedMuteStateByDeviceID.removeAll()
    }

    private func logUnsupportedOutputDeviceIfNeeded(_ deviceID: AudioDeviceID) {
        guard unsupportedOutputDeviceIDs.insert(deviceID).inserted else { return }
        MirageLogger.host("Default output device \(deviceID) does not expose writable mute or volume controls")
    }
}

final class CoreAudioHostAudioDeviceDriver: HostAudioDeviceDriving {
    func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = Self.defaultOutputDeviceAddress
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

    func readMuteState(for deviceID: AudioDeviceID) -> Bool? {
        var address = Self.outputMuteAddress
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

    func writeMuteState(_ muted: Bool, for deviceID: AudioDeviceID) -> Bool {
        var address = Self.outputMuteAddress
        guard isPropertyWritable(deviceID: deviceID, address: &address) else { return false }

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

    func writableVolumeElements(for deviceID: AudioDeviceID) -> [AudioObjectPropertyElement] {
        var elements: [AudioObjectPropertyElement] = []
        if isVolumeElementWritable(deviceID: deviceID, element: kAudioObjectPropertyElementMain) {
            elements.append(kAudioObjectPropertyElementMain)
        }

        let channelCount = max(0, outputChannelCount(for: deviceID))
        guard channelCount > 0 else { return elements }
        for channelIndex in 1...channelCount {
            let element = AudioObjectPropertyElement(channelIndex)
            if isVolumeElementWritable(deviceID: deviceID, element: element) {
                elements.append(element)
            }
        }
        return elements
    }

    func readVolumeScalar(for deviceID: AudioDeviceID, element: AudioObjectPropertyElement) -> Float? {
        var address = Self.outputVolumeAddress(element: element)
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }

        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &volume
        )
        guard status == noErr else {
            MirageLogger.error(.host, "Failed to read device volume: OSStatus \(status)")
            return nil
        }
        return volume
    }

    func writeVolumeScalar(
        _ volume: Float,
        for deviceID: AudioDeviceID,
        element: AudioObjectPropertyElement
    )
    -> Bool {
        var address = Self.outputVolumeAddress(element: element)
        guard isPropertyWritable(deviceID: deviceID, address: &address) else { return false }

        var value = Float32(max(0, min(1, volume)))
        let size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            size,
            &value
        )
        guard status == noErr else {
            MirageLogger.error(.host, "Failed to set device volume: OSStatus \(status)")
            return false
        }
        return true
    }

    func addDefaultOutputDeviceChangeListener(
        queue: DispatchQueue,
        handler: @escaping @Sendable () -> Void
    )
    -> HostAudioDefaultOutputListenerToken? {
        var address = Self.defaultOutputDeviceAddress
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            handler()
        }

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue,
            block
        )
        guard status == noErr else {
            MirageLogger.error(.host, "Failed to install audio output listener: OSStatus \(status)")
            return nil
        }
        return HostAudioDefaultOutputListenerToken(block: block, queue: queue)
    }

    func removeDefaultOutputDeviceChangeListener(_ token: HostAudioDefaultOutputListenerToken) {
        guard let block = token.block else { return }
        var address = Self.defaultOutputDeviceAddress
        let status = AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            token.queue,
            block
        )
        if status != noErr {
            MirageLogger.error(.host, "Failed to remove audio output listener: OSStatus \(status)")
        }
    }

    private func isVolumeElementWritable(
        deviceID: AudioDeviceID,
        element: AudioObjectPropertyElement
    )
    -> Bool {
        var address = Self.outputVolumeAddress(element: element)
        return isPropertyWritable(deviceID: deviceID, address: &address)
    }

    private func isPropertyWritable(
        deviceID: AudioDeviceID,
        address: inout AudioObjectPropertyAddress
    )
    -> Bool {
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        var settable = DarwinBoolean(false)
        let status = AudioObjectIsPropertySettable(deviceID, &address, &settable)
        guard status == noErr else {
            MirageLogger.error(.host, "Failed to query audio property mutability: OSStatus \(status)")
            return false
        }
        return settable.boolValue
    }

    private func outputChannelCount(for deviceID: AudioDeviceID) -> Int {
        var address = Self.outputStreamConfigurationAddress
        guard AudioObjectHasProperty(deviceID, &address) else { return 0 }

        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        guard sizeStatus == noErr, size > 0 else { return 0 }

        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPointer.deallocate() }

        let bufferList = rawPointer.bindMemory(to: AudioBufferList.self, capacity: 1)
        let dataStatus = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, bufferList)
        guard dataStatus == noErr else { return 0 }

        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        return buffers.reduce(0) { count, buffer in
            count + Int(buffer.mNumberChannels)
        }
    }

    private static let defaultOutputDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private static let outputMuteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    private static func outputVolumeAddress(element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
    }

    private static let outputStreamConfigurationAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
}

#endif
