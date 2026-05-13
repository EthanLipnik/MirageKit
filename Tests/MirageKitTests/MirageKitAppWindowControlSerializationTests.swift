//
//  MirageKitAppWindowControlSerializationTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

import Foundation
@testable import MirageKit
import Testing

@Suite("MirageKit App Window Control Serialization")
struct MirageKitAppWindowControlSerializationTests {
    @Test("Window removed from stream payload serialization")
    func windowRemovedFromStreamSerialization() throws {
        let payload = WindowRemovedFromStreamMessage(
            bundleIdentifier: "com.apple.dt.Xcode",
            streamID: 27,
            windowID: 12615,
            reason: .noLongerEligible
        )

        let envelope = try ControlMessage(type: .windowRemovedFromStream, content: payload)
        let (decodedEnvelope, _) = try requireParsedControlMessage(from: envelope.serialize())
        let decoded = try decodedEnvelope.decode(WindowRemovedFromStreamMessage.self)
        #expect(decoded.bundleIdentifier == "com.apple.dt.Xcode")
        #expect(decoded.streamID == 27)
        #expect(decoded.windowID == 12615)
        #expect(decoded.reason == .noLongerEligible)
    }

    @Test("App window inventory removes closed windows from visible and hidden entries")
    func appWindowInventoryRemovesClosedWindows() {
        let inventory = AppWindowInventoryMessage(
            bundleIdentifier: "com.apple.dt.Xcode",
            maxVisibleSlots: 3,
            slots: [
                .init(
                    slotIndex: 0,
                    streamID: 27,
                    mediaStreamID: 27,
                    window: .init(
                        windowID: 12615,
                        title: "Editor",
                        width: 1440,
                        height: 900,
                        isResizable: true
                    )
                ),
                .init(
                    slotIndex: 1,
                    streamID: 28,
                    mediaStreamID: 28,
                    window: .init(
                        windowID: 12616,
                        title: "Canvas",
                        width: 1440,
                        height: 900,
                        isResizable: true
                    )
                ),
            ],
            hiddenWindows: [
                .init(
                    windowID: 12617,
                    title: "Welcome",
                    width: 900,
                    height: 700,
                    isResizable: true
                ),
            ]
        )

        let visibleRemoval = inventory.removingWindow(windowID: 12615)
        #expect(visibleRemoval?.slots.map(\.window.windowID) == [12616])
        #expect(visibleRemoval?.hiddenWindows.map(\.windowID) == [12617])

        let hiddenRemoval = inventory.removingWindow(windowID: 12617)
        #expect(hiddenRemoval?.slots.map(\.window.windowID) == [12615, 12616])
        #expect(hiddenRemoval?.hiddenWindows.isEmpty == true)

        let emptyInventory = AppWindowInventoryMessage(
            bundleIdentifier: "com.apple.dt.Xcode",
            maxVisibleSlots: 1,
            slots: [
                .init(
                    slotIndex: 0,
                    streamID: 27,
                    mediaStreamID: 27,
                    window: .init(
                        windowID: 12615,
                        title: "Editor",
                        width: 1440,
                        height: 900,
                        isResizable: true
                    )
                ),
            ],
            hiddenWindows: []
        )
        #expect(emptyInventory.removingWindow(windowID: 12615) == nil)
    }

    @Test("App window inventory removal prunes atlas regions")
    func appWindowInventoryRemovalPrunesAtlasRegions() {
        let remainingRegion = MirageAppAtlasRegion(
            windowID: 12616,
            x: 0,
            y: 0,
            width: 1280,
            height: 720
        )
        let removedRegion = MirageAppAtlasRegion(
            windowID: 12615,
            x: 1280,
            y: 0,
            width: 1280,
            height: 720
        )
        let inventory = AppWindowInventoryMessage(
            bundleIdentifier: "com.apple.dt.Xcode",
            maxVisibleSlots: 2,
            slots: [
                .init(
                    slotIndex: 0,
                    streamID: 27,
                    mediaStreamID: 99,
                    window: .init(
                        windowID: 12615,
                        title: "Editor",
                        width: 1280,
                        height: 720,
                        isResizable: true
                    ),
                    atlasRegion: removedRegion
                ),
                .init(
                    slotIndex: 1,
                    streamID: 28,
                    mediaStreamID: 99,
                    window: .init(
                        windowID: 12616,
                        title: "Canvas",
                        width: 1280,
                        height: 720,
                        isResizable: true
                    ),
                    atlasRegion: remainingRegion
                ),
            ],
            hiddenWindows: [],
            atlasLayouts: [
                MirageAppAtlasLayout(
                    mediaStreamID: 99,
                    layoutEpoch: 4,
                    width: 2560,
                    height: 720,
                    regions: [remainingRegion, removedRegion]
                ),
            ]
        )

        let updated = inventory.removingWindow(windowID: 12615)

        #expect(updated?.slots.map(\.streamID) == [28])
        #expect(updated?.atlasLayouts?.first?.regions == [remainingRegion])
    }

    @Test("Window stream failed payload serialization")
    func windowStreamFailedSerialization() throws {
        let payload = WindowStreamFailedMessage(
            bundleIdentifier: "com.apple.dt.Xcode",
            windowID: 14674,
            title: "PokeApp - CanvasGreetingOverlay.swift",
            reason: "Dedicated display correction failed",
            userMessage: "Xcode could not be streamed."
        )

        let envelope = try ControlMessage(type: .windowStreamFailed, content: payload)
        let (decodedEnvelope, _) = try requireParsedControlMessage(from: envelope.serialize())
        let decoded = try decodedEnvelope.decode(WindowStreamFailedMessage.self)
        #expect(decoded.bundleIdentifier == "com.apple.dt.Xcode")
        #expect(decoded.windowID == 14674)
        #expect(decoded.title == "PokeApp - CanvasGreetingOverlay.swift")
        #expect(decoded.reason == "Dedicated display correction failed")
        #expect(decoded.userMessage == "Xcode could not be streamed.")
    }

    @Test("App window close-blocked alert payload serialization")
    func appWindowCloseBlockedAlertSerialization() throws {
        let payload = AppWindowCloseBlockedAlertMessage(
            bundleIdentifier: "com.apple.TextEdit",
            sourceWindowID: 901,
            presentingStreamID: 41,
            alertToken: "token-123",
            title: "Save changes?",
            message: "Do you want to save the changes made to this document?",
            actions: [
                .init(id: "action-0", title: "Cancel"),
                .init(id: "action-1", title: "Don't Save", isDestructive: true),
                .init(id: "action-2", title: "Save"),
            ]
        )

        let envelope = try ControlMessage(type: .appWindowCloseBlockedAlert, content: payload)
        let (decodedEnvelope, _) = try requireParsedControlMessage(from: envelope.serialize())
        let decoded = try decodedEnvelope.decode(AppWindowCloseBlockedAlertMessage.self)
        #expect(decoded.bundleIdentifier == "com.apple.TextEdit")
        #expect(decoded.sourceWindowID == 901)
        #expect(decoded.presentingStreamID == 41)
        #expect(decoded.alertToken == "token-123")
        #expect(decoded.actions.count == 3)
        #expect(decoded.actions[1].isDestructive)
    }

    @Test("App window close-alert action request payload serialization")
    func appWindowCloseAlertActionRequestSerialization() throws {
        let payload = AppWindowCloseAlertActionRequestMessage(
            alertToken: "token-abc",
            actionID: "action-2",
            presentingStreamID: 73
        )

        let envelope = try ControlMessage(type: .appWindowCloseAlertActionRequest, content: payload)
        let (decodedEnvelope, _) = try requireParsedControlMessage(from: envelope.serialize())
        let decoded = try decodedEnvelope.decode(AppWindowCloseAlertActionRequestMessage.self)
        #expect(decoded.alertToken == "token-abc")
        #expect(decoded.actionID == "action-2")
        #expect(decoded.presentingStreamID == 73)
    }

    @Test("App window close-alert action result payload serialization")
    func appWindowCloseAlertActionResultSerialization() throws {
        let payload = AppWindowCloseAlertActionResultMessage(
            alertToken: "token-result",
            actionID: "action-1",
            success: false,
            reason: "Presenting stream mismatch"
        )

        let envelope = try ControlMessage(type: .appWindowCloseAlertActionResult, content: payload)
        let (decodedEnvelope, _) = try requireParsedControlMessage(from: envelope.serialize())
        let decoded = try decodedEnvelope.decode(AppWindowCloseAlertActionResultMessage.self)
        #expect(decoded.alertToken == "token-result")
        #expect(decoded.actionID == "action-1")
        #expect(decoded.success == false)
        #expect(decoded.reason == "Presenting stream mismatch")
    }
}
