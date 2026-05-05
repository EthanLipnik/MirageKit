//
//  HostAudioMuteControllerTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/5/26.
//

#if os(macOS)
import CoreAudio
import Foundation
@testable import MirageKitHost
import Testing

@MainActor
@Suite("Host Audio Mute Controller")
struct HostAudioMuteControllerTests {
    @Test("Writable mute property is preferred and restored")
    func writableMutePropertyIsPreferredAndRestored() {
        let driver = RecordingHostAudioDeviceDriver(
            defaultDeviceID: 42,
            muteStateByDeviceID: [42: false],
            writableMuteDeviceIDs: [42],
            writableVolumeElementsByDeviceID: [42: [1]]
        )
        let controller = HostAudioMuteController(driver: driver)

        controller.setMuted(true)
        controller.setMuted(false)

        #expect(driver.muteWrites == [
            .init(deviceID: 42, muted: true),
            .init(deviceID: 42, muted: false),
        ])
        #expect(driver.volumeWrites.isEmpty)
    }

    @Test("Volume fallback mutes and restores writable elements")
    func volumeFallbackMutesAndRestoresWritableElements() {
        let driver = RecordingHostAudioDeviceDriver(
            defaultDeviceID: 77,
            muteStateByDeviceID: [:],
            writableMuteDeviceIDs: [],
            writableVolumeElementsByDeviceID: [77: [1, 2]],
            volumeByDeviceAndElement: [
                RecordingHostAudioDeviceDriver.VolumeKey(deviceID: 77, element: 1): 0.75,
                RecordingHostAudioDeviceDriver.VolumeKey(deviceID: 77, element: 2): 0.50,
            ]
        )
        let controller = HostAudioMuteController(driver: driver)

        controller.setMuted(true)
        controller.setMuted(false)

        #expect(driver.volumeWrites == [
            .init(deviceID: 77, element: 1, volume: 0),
            .init(deviceID: 77, element: 2, volume: 0),
            .init(deviceID: 77, element: 1, volume: 0.75),
            .init(deviceID: 77, element: 2, volume: 0.50),
        ])
    }
}

private final class RecordingHostAudioDeviceDriver: HostAudioDeviceDriving {
    struct VolumeKey: Hashable {
        let deviceID: AudioDeviceID
        let element: AudioObjectPropertyElement
    }

    struct VolumeWrite: Equatable {
        let deviceID: AudioDeviceID
        let element: AudioObjectPropertyElement
        let volume: Float
    }

    struct MuteWrite: Equatable {
        let deviceID: AudioDeviceID
        let muted: Bool
    }

    private let defaultDeviceID: AudioDeviceID?
    private var muteStateByDeviceID: [AudioDeviceID: Bool]
    private let writableMuteDeviceIDs: Set<AudioDeviceID>
    private let writableVolumeElementsByDeviceID: [AudioDeviceID: [AudioObjectPropertyElement]]
    private var volumeByDeviceAndElement: [VolumeKey: Float]

    private(set) var muteWrites: [MuteWrite] = []
    private(set) var volumeWrites: [VolumeWrite] = []

    init(
        defaultDeviceID: AudioDeviceID?,
        muteStateByDeviceID: [AudioDeviceID: Bool],
        writableMuteDeviceIDs: Set<AudioDeviceID>,
        writableVolumeElementsByDeviceID: [AudioDeviceID: [AudioObjectPropertyElement]],
        volumeByDeviceAndElement: [VolumeKey: Float] = [:]
    ) {
        self.defaultDeviceID = defaultDeviceID
        self.muteStateByDeviceID = muteStateByDeviceID
        self.writableMuteDeviceIDs = writableMuteDeviceIDs
        self.writableVolumeElementsByDeviceID = writableVolumeElementsByDeviceID
        self.volumeByDeviceAndElement = volumeByDeviceAndElement
    }

    func defaultOutputDeviceID() -> AudioDeviceID? {
        defaultDeviceID
    }

    func readMuteState(for deviceID: AudioDeviceID) -> Bool? {
        muteStateByDeviceID[deviceID]
    }

    func writeMuteState(_ muted: Bool, for deviceID: AudioDeviceID) -> Bool {
        guard writableMuteDeviceIDs.contains(deviceID) else { return false }
        muteStateByDeviceID[deviceID] = muted
        muteWrites.append(MuteWrite(deviceID: deviceID, muted: muted))
        return true
    }

    func writableVolumeElements(for deviceID: AudioDeviceID) -> [AudioObjectPropertyElement] {
        writableVolumeElementsByDeviceID[deviceID] ?? []
    }

    func readVolumeScalar(for deviceID: AudioDeviceID, element: AudioObjectPropertyElement) -> Float? {
        volumeByDeviceAndElement[VolumeKey(deviceID: deviceID, element: element)]
    }

    func writeVolumeScalar(
        _ volume: Float,
        for deviceID: AudioDeviceID,
        element: AudioObjectPropertyElement
    )
    -> Bool {
        let key = VolumeKey(deviceID: deviceID, element: element)
        guard volumeByDeviceAndElement[key] != nil else { return false }
        volumeByDeviceAndElement[key] = volume
        volumeWrites.append(VolumeWrite(deviceID: deviceID, element: element, volume: volume))
        return true
    }

    func addDefaultOutputDeviceChangeListener(
        queue: DispatchQueue,
        handler: @escaping @Sendable () -> Void
    )
    -> HostAudioDefaultOutputListenerToken? {
        HostAudioDefaultOutputListenerToken(block: nil)
    }

    func removeDefaultOutputDeviceChangeListener(_ token: HostAudioDefaultOutputListenerToken) {}
}
#endif
