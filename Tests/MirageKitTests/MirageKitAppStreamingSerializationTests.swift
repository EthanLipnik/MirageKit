//
//  MirageKitAppStreamingSerializationTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

import Foundation
@testable import MirageKit
import Testing

@Suite("MirageKit App Streaming Serialization")
struct MirageKitAppStreamingSerializationTests {
    @Test("Select app message includes max visible slot count")
    func selectAppMessageMaxVisibleSlotsSerialization() throws {
        let request = SelectAppMessage(
            bundleIdentifier: "com.apple.mail",
            targetFrameRate: 60,
            enteredBitrate: 600_000_000,
            allowEncoderCatchUpQualityAdjustment: true,
            maxConcurrentVisibleWindows: 8
        )
        let envelope = try ControlMessage(type: .selectApp, content: request)
        let (decodedEnvelope, _) = try requireParsedControlMessage(from: envelope.serialize())
        let decoded = try decodedEnvelope.decode(SelectAppMessage.self)
        #expect(decoded.bundleIdentifier == "com.apple.mail")
        #expect(decoded.maxConcurrentVisibleWindows == 8)
        #expect(decoded.enteredBitrate == 600_000_000)
        #expect(decoded.allowEncoderCatchUpQualityAdjustment == true)
    }

    @Test("App list request supports icon reset and priority ordering")
    func appListRequestSerialization() throws {
        let request = try AppListRequestMessage(
            forceRefresh: true,
            forceIconReset: true,
            priorityBundleIdentifiers: [
                "com.apple.mail",
                "com.apple.safari",
            ],
            knownIconBundleIdentifiers: ["com.apple.mail"],
            requestID: #require(UUID(uuidString: "00000000-0000-0000-0000-000000000123"))
        )

        let envelope = try ControlMessage(type: .appListRequest, content: request)
        let (decodedEnvelope, _) = try requireParsedControlMessage(from: envelope.serialize())
        let decoded = try decodedEnvelope.decode(AppListRequestMessage.self)

        #expect(decoded.forceRefresh)
        #expect(decoded.forceIconReset)
        #expect(decoded.priorityBundleIdentifiers == ["com.apple.mail", "com.apple.safari"])
        #expect(decoded.knownIconBundleIdentifiers == ["com.apple.mail"])
        #expect(decoded.requestID.uuidString.lowercased() == "00000000-0000-0000-0000-000000000123")
    }

    @Test("App list progress with inline icons serializes")
    func appListProgressWithInlineIconsSerialization() throws {
        let progressApps = [
            MirageInstalledApp(
                bundleIdentifier: "com.apple.mail",
                name: "Mail",
                path: "/Applications/Mail.app",
                iconData: Data([0x01, 0x02, 0x03]),
                version: "1.0",
                isRunning: true,
                isBeingStreamed: false
            ),
        ]
        let requestID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000321"))
        let appListCompletion = AppListCompleteMessage(requestID: requestID, totalAppCount: 1)
        let appListCompletionEnvelope = try ControlMessage(type: .appListComplete, content: appListCompletion)
        let (decodedAppListCompletionEnvelope, _) = try requireParsedControlMessage(
            from: appListCompletionEnvelope.serialize()
        )
        let decodedAppListCompletion = try decodedAppListCompletionEnvelope.decode(AppListCompleteMessage.self)
        #expect(decodedAppListCompletion.requestID == requestID)
        #expect(decodedAppListCompletion.totalAppCount == 1)

        let progress = AppListProgressMessage(requestID: requestID, apps: progressApps)
        let progressEnvelope = try ControlMessage(type: .appListProgress, content: progress)
        let (decodedProgressEnvelope, _) = try requireParsedControlMessage(from: progressEnvelope.serialize())
        let decodedProgress = try decodedProgressEnvelope.decode(AppListProgressMessage.self)
        #expect(decodedProgress.requestID == requestID)
        #expect(decodedProgress.apps.count == 1)
        #expect(decodedProgress.apps[0].bundleIdentifier == "com.apple.mail")
        #expect(decodedProgress.apps[0].iconData == Data([0x01, 0x02, 0x03]))
    }

    @Test("App window inventory and swap messages serialize")
    func appWindowInventoryAndSwapSerialization() throws {
        let atlasRegion = MirageAppAtlasRegion(
            windowID: 9001,
            x: 32,
            y: 48,
            width: 1440,
            height: 900,
            zIndex: 1
        )
        let atlasLayout = MirageAppAtlasLayout(
            mediaStreamID: 41,
            width: 2048,
            height: 1536,
            regions: [atlasRegion]
        )
        let metadata = AppWindowInventoryMessage.WindowMetadata(
            windowID: 9001,
            title: "Inbox",
            width: 1440,
            height: 900,
            isResizable: true
        )
        let inventory = AppWindowInventoryMessage(
            bundleIdentifier: "com.apple.mail",
            maxVisibleSlots: 8,
            slots: [
                .init(slotIndex: 0, streamID: 141, mediaStreamID: 41, window: metadata, atlasRegion: atlasRegion),
            ],
            hiddenWindows: [
                .init(
                    windowID: 9002,
                    title: "Draft",
                    width: 1280,
                    height: 860,
                    isResizable: true
                ),
            ],
            atlasLayouts: [atlasLayout]
        )
        let inventoryEnvelope = try ControlMessage(type: .appWindowInventory, content: inventory)
        let (decodedInventoryEnvelope, _) = try requireParsedControlMessage(from: inventoryEnvelope.serialize())
        let decodedInventory = try decodedInventoryEnvelope.decode(AppWindowInventoryMessage.self)
        #expect(decodedInventory.bundleIdentifier == "com.apple.mail")
        #expect(decodedInventory.maxVisibleSlots == 8)
        #expect(decodedInventory.slots.count == 1)
        #expect(decodedInventory.slots[0].mediaStreamID == 41)
        #expect(decodedInventory.slots[0].streamID == 141)
        #expect(decodedInventory.slots[0].window.windowID == 9001)
        #expect(decodedInventory.slots[0].atlasRegion == atlasRegion)
        #expect(decodedInventory.hiddenWindows.count == 1)
        #expect(decodedInventory.atlasLayouts == [atlasLayout])

        let swapRequest = AppWindowSwapRequestMessage(
            bundleIdentifier: "com.apple.mail",
            targetSlotStreamID: 141,
            targetWindowID: 9002
        )
        let requestEnvelope = try ControlMessage(type: .appWindowSwapRequest, content: swapRequest)
        let (decodedRequestEnvelope, _) = try requireParsedControlMessage(from: requestEnvelope.serialize())
        let decodedSwapRequest = try decodedRequestEnvelope.decode(AppWindowSwapRequestMessage.self)
        #expect(decodedSwapRequest.targetSlotStreamID == 141)
        #expect(decodedSwapRequest.targetWindowID == 9002)

        let swappedRegion = MirageAppAtlasRegion(
            windowID: 9002,
            x: 32,
            y: 48,
            width: 1280,
            height: 860,
            zIndex: 1
        )
        let swappedLayout = MirageAppAtlasLayout(
            mediaStreamID: 41,
            width: 2048,
            height: 1536,
            regions: [swappedRegion]
        )
        let swapResult = AppWindowSwapResultMessage(
            bundleIdentifier: "com.apple.mail",
            targetSlotStreamID: 141,
            mediaStreamID: 41,
            windowID: 9002,
            success: true,
            reason: nil,
            atlasRegion: swappedRegion,
            atlasLayouts: [swappedLayout]
        )
        let resultEnvelope = try ControlMessage(type: .appWindowSwapResult, content: swapResult)
        let (decodedResultEnvelope, _) = try requireParsedControlMessage(from: resultEnvelope.serialize())
        let decodedSwapResult = try decodedResultEnvelope.decode(AppWindowSwapResultMessage.self)
        #expect(decodedSwapResult.success == true)
        #expect(decodedSwapResult.targetSlotStreamID == 141)
        #expect(decodedSwapResult.mediaStreamID == 41)
        #expect(decodedSwapResult.windowID == 9002)
        #expect(decodedSwapResult.atlasRegion == swappedRegion)
        #expect(decodedSwapResult.atlasLayouts == [swappedLayout])
    }

    @Test("App atlas payload keeps logical and media stream keys distinct")
    func appAtlasPayloadKeepsLogicalAndMediaStreamKeysDistinct() throws {
        let window = AppStreamStartedMessage.AppStreamWindow(
            streamID: 141,
            mediaStreamID: 41,
            windowID: 9001,
            title: "Inbox",
            width: 1440,
            height: 900,
            isResizable: true
        )

        let encoded = try JSONEncoder().encode(window)
        let object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        #expect((object["streamID"] as? NSNumber)?.uint64Value == 141)
        #expect((object["mediaStreamID"] as? NSNumber)?.uint64Value == 41)
    }

    @Test("App atlas media update serializes startup and layout metadata")
    func appAtlasMediaUpdateSerialization() throws {
        let startupAttemptID = try #require(UUID(uuidString: "00000000-0000-0000-0000-0000000009F0"))
        let region = MirageAppAtlasRegion(
            windowID: 9001,
            x: 128,
            y: 64,
            width: 1440,
            height: 900,
            zIndex: 2,
            isFocused: true
        )
        let layout = MirageAppAtlasLayout(
            mediaStreamID: 41,
            layoutEpoch: 7,
            width: 4096,
            height: 2304,
            regions: [region]
        )
        let update = AppAtlasMediaUpdateMessage(
            mediaStreamID: 41,
            width: 4096,
            height: 2304,
            codec: .hevc,
            frameRate: 120,
            dimensionToken: 12,
            layoutEpoch: 7,
            acceptedPacketSize: 1180,
            layout: layout,
            startupAttemptID: startupAttemptID
        )

        let envelope = try ControlMessage(type: .appAtlasMediaUpdate, content: update)
        let (decodedEnvelope, _) = try requireParsedControlMessage(from: envelope.serialize())
        let decoded = try decodedEnvelope.decode(AppAtlasMediaUpdateMessage.self)

        #expect(decodedEnvelope.type == .appAtlasMediaUpdate)
        #expect(decoded.mediaStreamID == 41)
        #expect(decoded.width == 4096)
        #expect(decoded.height == 2304)
        #expect(decoded.codec == .hevc)
        #expect(decoded.frameRate == 120)
        #expect(decoded.dimensionToken == 12)
        #expect(decoded.layoutEpoch == 7)
        #expect(decoded.acceptedPacketSize == 1180)
        #expect(decoded.layout == layout)
        #expect(decoded.startupAttemptID == startupAttemptID)
    }

    @Test("App window resize result serializes terminal outcome")
    func appWindowResizeResultSerialization() throws {
        let result = AppWindowResizeResultMessage(
            streamID: 141,
            mediaStreamID: 41,
            windowID: 9001,
            outcome: .notResizable,
            requestedWidth: 1600,
            requestedHeight: 1000,
            observedWidth: 1440,
            observedHeight: 900,
            minWidth: 800,
            minHeight: 600,
            reason: "sizeAttributeNotSettable"
        )

        let envelope = try ControlMessage(type: .appWindowResizeResult, content: result)
        let (decodedEnvelope, _) = try requireParsedControlMessage(from: envelope.serialize())
        let decoded = try decodedEnvelope.decode(AppWindowResizeResultMessage.self)

        #expect(decoded.streamID == 141)
        #expect(decoded.mediaStreamID == 41)
        #expect(decoded.windowID == 9001)
        #expect(decoded.outcome == .notResizable)
        #expect(decoded.requestedWidth == 1600)
        #expect(decoded.requestedHeight == 1000)
        #expect(decoded.observedWidth == 1440)
        #expect(decoded.observedHeight == 900)
        #expect(decoded.minWidth == 800)
        #expect(decoded.minHeight == 600)
        #expect(decoded.reason == "sizeAttributeNotSettable")
    }
}
