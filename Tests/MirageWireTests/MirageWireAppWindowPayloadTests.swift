//
//  MirageWireAppWindowPayloadTests.swift
//  MirageWire
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation
import MirageMedia
import MirageWire
import Testing

@Suite("MirageWire App Window Payloads")
struct MirageWireAppWindowPayloadTests {
    @Test("App window inventory and swap payloads round-trip in wire target")
    func appWindowInventoryAndSwapPayloadsRoundTripInWireTarget() throws {
        let sessionID = try #require(UUID(uuidString: "74000000-0000-0000-0000-000000000001"))
        let atlasRegion = MirageMedia.MirageAppAtlasRegion(
            windowID: 9_001,
            x: 32,
            y: 48,
            width: 1_440,
            height: 900,
            zIndex: 1
        )
        let atlasLayout = MirageMedia.MirageAppAtlasLayout(
            mediaStreamID: 41,
            layoutEpoch: 3,
            width: 2_048,
            height: 1_536,
            regions: [atlasRegion]
        )
        let metadata = MirageWire.AppWindowInventoryMessage.WindowMetadata(
            windowID: 9_001,
            title: "Inbox",
            width: 1_440,
            height: 900,
            isResizable: true
        )
        let inventory = MirageWire.AppWindowInventoryMessage(
            bundleIdentifier: "com.apple.mail",
            appSessionID: sessionID,
            maxVisibleSlots: 8,
            slots: [
                MirageWire.AppWindowInventoryMessage.Slot(
                    slotIndex: 0,
                    streamID: 141,
                    mediaStreamID: 41,
                    window: metadata,
                    atlasRegion: atlasRegion
                ),
            ],
            hiddenWindows: [
                MirageWire.AppWindowInventoryMessage.WindowMetadata(
                    windowID: 9_002,
                    title: "Draft",
                    width: 1_280,
                    height: 860,
                    isResizable: true
                ),
            ],
            atlasLayouts: [atlasLayout]
        )
        let inventoryEnvelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .appWindowInventory, content: inventory).serialize()
        ).message
        let decodedInventory = try inventoryEnvelope.decode(MirageWire.AppWindowInventoryMessage.self)

        #expect(decodedInventory.bundleIdentifier == "com.apple.mail")
        #expect(decodedInventory.appSessionID == sessionID)
        #expect(decodedInventory.maxVisibleSlots == 8)
        #expect(decodedInventory.slots.first?.mediaStreamID == 41)
        #expect(decodedInventory.slots.first?.streamID == 141)
        #expect(decodedInventory.slots.first?.window == metadata)
        #expect(decodedInventory.slots.first?.atlasRegion == atlasRegion)
        #expect(decodedInventory.hiddenWindows.map(\.windowID) == [9_002])
        #expect(decodedInventory.atlasLayouts == [atlasLayout])

        let swapRequest = MirageWire.AppWindowSwapRequestMessage(
            bundleIdentifier: "com.apple.mail",
            targetSlotStreamID: 141,
            targetWindowID: 9_002
        )
        let requestEnvelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .appWindowSwapRequest, content: swapRequest).serialize()
        ).message
        let decodedRequest = try requestEnvelope.decode(MirageWire.AppWindowSwapRequestMessage.self)

        #expect(decodedRequest.bundleIdentifier == "com.apple.mail")
        #expect(decodedRequest.targetSlotStreamID == 141)
        #expect(decodedRequest.targetWindowID == 9_002)

        let swappedRegion = MirageMedia.MirageAppAtlasRegion(
            windowID: 9_002,
            x: 32,
            y: 48,
            width: 1_280,
            height: 860,
            zIndex: 1
        )
        let swappedLayout = MirageMedia.MirageAppAtlasLayout(
            mediaStreamID: 41,
            layoutEpoch: 4,
            width: 2_048,
            height: 1_536,
            regions: [swappedRegion]
        )
        let swapResult = MirageWire.AppWindowSwapResultMessage(
            bundleIdentifier: "com.apple.mail",
            targetSlotStreamID: 141,
            mediaStreamID: 41,
            windowID: 9_002,
            success: true,
            reason: nil,
            atlasRegion: swappedRegion,
            atlasLayouts: [swappedLayout]
        )
        let resultEnvelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .appWindowSwapResult, content: swapResult).serialize()
        ).message
        let decodedResult = try resultEnvelope.decode(MirageWire.AppWindowSwapResultMessage.self)

        #expect(decodedResult.success)
        #expect(decodedResult.targetSlotStreamID == 141)
        #expect(decodedResult.mediaStreamID == 41)
        #expect(decodedResult.windowID == 9_002)
        #expect(decodedResult.atlasRegion == swappedRegion)
        #expect(decodedResult.atlasLayouts == [swappedLayout])
    }

    @Test("App window inventory removes windows and prunes atlas regions in wire target")
    func appWindowInventoryRemovesWindowsAndPrunesAtlasRegionsInWireTarget() {
        let remainingRegion = MirageMedia.MirageAppAtlasRegion(
            windowID: 12_616,
            x: 0,
            y: 0,
            width: 1_280,
            height: 720
        )
        let removedRegion = MirageMedia.MirageAppAtlasRegion(
            windowID: 12_615,
            x: 1_280,
            y: 0,
            width: 1_280,
            height: 720
        )
        let inventory = MirageWire.AppWindowInventoryMessage(
            bundleIdentifier: "com.apple.dt.Xcode",
            maxVisibleSlots: 2,
            slots: [
                MirageWire.AppWindowInventoryMessage.Slot(
                    slotIndex: 0,
                    streamID: 27,
                    mediaStreamID: 99,
                    window: MirageWire.AppWindowInventoryMessage.WindowMetadata(
                        windowID: 12_615,
                        title: "Editor",
                        width: 1_280,
                        height: 720,
                        isResizable: true
                    ),
                    atlasRegion: removedRegion
                ),
                MirageWire.AppWindowInventoryMessage.Slot(
                    slotIndex: 1,
                    streamID: 28,
                    mediaStreamID: 99,
                    window: MirageWire.AppWindowInventoryMessage.WindowMetadata(
                        windowID: 12_616,
                        title: "Canvas",
                        width: 1_280,
                        height: 720,
                        isResizable: true
                    ),
                    atlasRegion: remainingRegion
                ),
            ],
            hiddenWindows: [
                MirageWire.AppWindowInventoryMessage.WindowMetadata(
                    windowID: 12_617,
                    title: "Welcome",
                    width: 900,
                    height: 700,
                    isResizable: true
                ),
            ],
            atlasLayouts: [
                MirageMedia.MirageAppAtlasLayout(
                    mediaStreamID: 99,
                    layoutEpoch: 4,
                    width: 2_560,
                    height: 720,
                    regions: [remainingRegion, removedRegion]
                ),
            ]
        )

        let visibleRemoval = inventory.removingWindow(windowID: 12_615)
        #expect(visibleRemoval?.slots.map(\.streamID) == [28])
        #expect(visibleRemoval?.hiddenWindows.map(\.windowID) == [12_617])
        #expect(visibleRemoval?.atlasLayouts?.first?.regions == [remainingRegion])

        let hiddenRemoval = inventory.removingWindow(windowID: 12_617)
        #expect(hiddenRemoval?.slots.map(\.streamID) == [27, 28])
        #expect(hiddenRemoval?.hiddenWindows.isEmpty == true)

        let emptyInventory = MirageWire.AppWindowInventoryMessage(
            bundleIdentifier: "com.apple.dt.Xcode",
            maxVisibleSlots: 1,
            slots: [
                MirageWire.AppWindowInventoryMessage.Slot(
                    slotIndex: 0,
                    streamID: 27,
                    mediaStreamID: 27,
                    window: MirageWire.AppWindowInventoryMessage.WindowMetadata(
                        windowID: 12_615,
                        title: "Editor",
                        width: 1_440,
                        height: 900,
                        isResizable: true
                    )
                ),
            ],
            hiddenWindows: []
        )
        #expect(emptyInventory.removingWindow(windowID: 12_615) == nil)
    }

    @Test("App window lifecycle payloads round-trip in wire target")
    func appWindowLifecyclePayloadsRoundTripInWireTarget() throws {
        let appSessionID = try #require(UUID(uuidString: "74000000-0000-0000-0000-000000000002"))
        let region = MirageMedia.MirageAppAtlasRegion(
            windowID: 14_674,
            x: 64,
            y: 96,
            width: 1_440,
            height: 900,
            zIndex: 2,
            isFocused: true
        )
        let layout = MirageMedia.MirageAppAtlasLayout(
            mediaStreamID: 88,
            layoutEpoch: 5,
            width: 2_048,
            height: 1_536,
            regions: [region]
        )
        let added = MirageWire.WindowAddedToStreamMessage(
            bundleIdentifier: "com.apple.dt.Xcode",
            appSessionID: appSessionID,
            streamID: 77,
            mediaStreamID: 88,
            windowID: 14_674,
            title: "Canvas",
            width: 1_440,
            height: 900,
            isResizable: true,
            atlasRegion: region,
            atlasLayouts: [layout]
        )
        let addedEnvelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .windowAddedToStream, content: added).serialize()
        ).message
        let decodedAdded = try addedEnvelope.decode(MirageWire.WindowAddedToStreamMessage.self)

        #expect(decodedAdded.bundleIdentifier == "com.apple.dt.Xcode")
        #expect(decodedAdded.appSessionID == appSessionID)
        #expect(decodedAdded.streamID == 77)
        #expect(decodedAdded.mediaStreamID == 88)
        #expect(decodedAdded.windowID == 14_674)
        #expect(decodedAdded.atlasRegion == region)
        #expect(decodedAdded.atlasLayouts == [layout])

        let removed = MirageWire.WindowRemovedFromStreamMessage(
            bundleIdentifier: "com.apple.dt.Xcode",
            appSessionID: appSessionID,
            streamID: 77,
            windowID: 14_674,
            reason: .noLongerEligible
        )
        let removedEnvelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .windowRemovedFromStream, content: removed).serialize()
        ).message
        let decodedRemoved = try removedEnvelope.decode(MirageWire.WindowRemovedFromStreamMessage.self)

        #expect(decodedRemoved.streamID == 77)
        #expect(decodedRemoved.windowID == 14_674)
        #expect(decodedRemoved.reason == .noLongerEligible)

        let failure = MirageWire.WindowStreamFailedMessage(
            bundleIdentifier: "com.apple.dt.Xcode",
            windowID: 14_674,
            title: "Canvas",
            reason: "Dedicated display correction failed",
            failureCode: .windowPlacementFailed,
            userMessage: "Xcode could not be streamed."
        )
        let failureEnvelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .windowStreamFailed, content: failure).serialize()
        ).message
        let decodedFailure = try failureEnvelope.decode(MirageWire.WindowStreamFailedMessage.self)

        #expect(decodedFailure.windowID == 14_674)
        #expect(decodedFailure.failureCode == .windowPlacementFailed)
        #expect(decodedFailure.userMessage == "Xcode could not be streamed.")

        let terminated = MirageWire.AppTerminatedMessage(
            bundleIdentifier: "com.apple.dt.Xcode",
            closedWindowIDs: [14_674, 14_675],
            hasRemainingWindows: false
        )
        let terminatedEnvelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .appTerminated, content: terminated).serialize()
        ).message
        let decodedTerminated = try terminatedEnvelope.decode(MirageWire.AppTerminatedMessage.self)

        #expect(decodedTerminated.bundleIdentifier == "com.apple.dt.Xcode")
        #expect(decodedTerminated.closedWindowIDs == [14_674, 14_675])
        #expect(decodedTerminated.hasRemainingWindows == false)
    }

    @Test("App window resize result payload round-trips in wire target")
    func appWindowResizeResultPayloadRoundTripsInWireTarget() throws {
        let result = MirageWire.AppWindowResizeResultMessage(
            streamID: 141,
            mediaStreamID: 41,
            windowID: 9_001,
            outcome: .notResizable,
            requestedWidth: 1_600,
            requestedHeight: 1_000,
            observedWidth: 1_440,
            observedHeight: 900,
            minWidth: 800,
            minHeight: 600,
            reason: "sizeAttributeNotSettable"
        )
        let envelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .appWindowResizeResult, content: result).serialize()
        ).message
        let decoded = try envelope.decode(MirageWire.AppWindowResizeResultMessage.self)

        #expect(decoded.streamID == 141)
        #expect(decoded.mediaStreamID == 41)
        #expect(decoded.windowID == 9_001)
        #expect(decoded.outcome == .notResizable)
        #expect(decoded.requestedWidth == 1_600)
        #expect(decoded.requestedHeight == 1_000)
        #expect(decoded.observedWidth == 1_440)
        #expect(decoded.observedHeight == 900)
        #expect(decoded.minWidth == 800)
        #expect(decoded.minHeight == 600)
        #expect(decoded.reason == "sizeAttributeNotSettable")
    }
}
