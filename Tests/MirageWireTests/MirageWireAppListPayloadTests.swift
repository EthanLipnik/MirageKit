//
//  MirageWireAppListPayloadTests.swift
//  MirageWire
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation
import MirageWire
import Testing

@Suite("MirageWire App List Payloads")
struct MirageWireAppListPayloadTests {
    @Test("App list request normalizes bundle identifier hints in wire target")
    func appListRequestNormalizesBundleIdentifiersInWireTarget() throws {
        let requestID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000123"))
        let message = MirageWire.AppListRequestMessage(
            forceRefresh: true,
            forceIconReset: true,
            priorityBundleIdentifiers: [
                " com.apple.Mail ",
                "com.apple.mail",
                "",
                "COM.APPLE.SAFARI",
            ],
            knownIconBundleIdentifiers: [
                " COM.APPLE.MAIL ",
                "com.apple.preview",
                "com.apple.preview",
            ],
            requestID: requestID
        )

        let envelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .appListRequest, content: message).serialize()
        ).message
        let decoded = try envelope.decode(MirageWire.AppListRequestMessage.self)

        #expect(decoded.forceRefresh)
        #expect(decoded.forceIconReset)
        #expect(decoded.priorityBundleIdentifiers == ["com.apple.mail", "com.apple.safari"])
        #expect(decoded.knownIconBundleIdentifiers == ["com.apple.mail", "com.apple.preview"])
        #expect(decoded.requestID == requestID)
    }

    @Test("App list completion and progress payloads round-trip in wire target")
    func appListCompletionAndProgressPayloadsRoundTripInWireTarget() throws {
        let requestID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000321"))
        let completion = MirageWire.AppListCompleteMessage(requestID: requestID, totalAppCount: -4)
        let completionEnvelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .appListComplete, content: completion).serialize()
        ).message
        let decodedCompletion = try completionEnvelope.decode(MirageWire.AppListCompleteMessage.self)
        #expect(decodedCompletion.requestID == requestID)
        #expect(decodedCompletion.totalAppCount == 0)

        let iconData = Data([0x01, 0x02, 0x03])
        let app = MirageWire.MirageInstalledApp(
            bundleIdentifier: "com.apple.mail",
            name: "Mail",
            path: "/Applications/Mail.app",
            iconData: iconData,
            version: "1.0",
            isRunning: true,
            isBeingStreamed: false
        )
        let progress = MirageWire.AppListProgressMessage(requestID: requestID, apps: [app])
        let progressEnvelope = try parsedControlMessage(
            from: MirageWire.ControlMessage(type: .appListProgress, content: progress).serialize()
        ).message
        let decodedProgress = try progressEnvelope.decode(MirageWire.AppListProgressMessage.self)

        #expect(decodedProgress.requestID == requestID)
        #expect(decodedProgress.apps.count == 1)
        #expect(decodedProgress.apps[0].bundleIdentifier == "com.apple.mail")
        #expect(decodedProgress.apps[0].name == "Mail")
        #expect(decodedProgress.apps[0].iconData == iconData)
        #expect(decodedProgress.apps[0].isRunning)
    }
}
