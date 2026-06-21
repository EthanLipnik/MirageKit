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
            writableMuteDeviceIDs: [42]
        )
        let controller = HostAudioMuteController(driver: driver)

        controller.setMuted(true)
        controller.setMuted(false)

        #expect(driver.muteWrites == [
            .init(deviceID: 42, muted: true),
            .init(deviceID: 42, muted: false),
        ])
    }

    @Test("Unsupported output device is left untouched")
    func unsupportedOutputDeviceIsLeftUntouched() {
        let driver = RecordingHostAudioDeviceDriver(
            defaultDeviceID: 77,
            muteStateByDeviceID: [:],
            writableMuteDeviceIDs: []
        )
        let controller = HostAudioMuteController(driver: driver)

        controller.setMuted(true)
        controller.setMuted(false)

        #expect(driver.muteWrites.isEmpty)
    }

    @Test("Default output changes are muted while requested")
    func defaultOutputChangesAreMutedWhileRequested() async {
        let driver = RecordingHostAudioDeviceDriver(
            defaultDeviceID: 42,
            muteStateByDeviceID: [42: false, 99: false],
            writableMuteDeviceIDs: [42, 99]
        )
        let controller = HostAudioMuteController(driver: driver)

        controller.setMuted(true)
        driver.defaultDeviceID = 99
        driver.notifyDefaultOutputDeviceChanged()
        await Task.yield()
        controller.setMuted(false)

        #expect(Array(driver.muteWrites.prefix(2)) == [
            .init(deviceID: 42, muted: true),
            .init(deviceID: 99, muted: true),
        ])
        #expect(Set(driver.muteWrites.dropFirst(2)) == [
            .init(deviceID: 42, muted: false),
            .init(deviceID: 99, muted: false),
        ])
        #expect(driver.removedDefaultOutputListenerCount == 1)
    }
}

private final class RecordingHostAudioDeviceDriver: HostAudioDeviceDriving {
    struct MuteWrite: Equatable, Hashable {
        let deviceID: AudioDeviceID
        let muted: Bool
    }

    var defaultDeviceID: AudioDeviceID?
    private var muteStateByDeviceID: [AudioDeviceID: Bool]
    private let writableMuteDeviceIDs: Set<AudioDeviceID>

    private(set) var muteWrites: [MuteWrite] = []
    private(set) var removedDefaultOutputListenerCount = 0
    private var defaultOutputListener: (queue: DispatchQueue, handler: @Sendable () -> Void)?

    init(
        defaultDeviceID: AudioDeviceID?,
        muteStateByDeviceID: [AudioDeviceID: Bool],
        writableMuteDeviceIDs: Set<AudioDeviceID>
    ) {
        self.defaultDeviceID = defaultDeviceID
        self.muteStateByDeviceID = muteStateByDeviceID
        self.writableMuteDeviceIDs = writableMuteDeviceIDs
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

    func addDefaultOutputDeviceChangeListener(
        queue: DispatchQueue,
        handler: @escaping @Sendable () -> Void
    )
    -> HostAudioDefaultOutputListenerToken? {
        defaultOutputListener = (queue: queue, handler: handler)
        return HostAudioDefaultOutputListenerToken(block: nil)
    }

    func removeDefaultOutputDeviceChangeListener(_: HostAudioDefaultOutputListenerToken) {
        defaultOutputListener = nil
        removedDefaultOutputListenerCount += 1
    }

    func notifyDefaultOutputDeviceChanged() {
        defaultOutputListener?.queue.sync {
            defaultOutputListener?.handler()
        }
    }
}
#endif
