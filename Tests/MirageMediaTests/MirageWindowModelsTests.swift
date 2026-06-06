//
//  MirageWindowModelsTests.swift
//  MirageMedia
//
//  Created by Ethan Lipnik on 6/5/26.
//

import CoreGraphics
import Foundation
import MirageMedia
import Testing

@Suite("MirageMedia Window Models")
struct MirageWindowModelsTests {
    @Test("Application identity and window display names stay portable")
    func applicationIdentityAndWindowDisplayNamesStayPortable() throws {
        let app = MirageMedia.MirageApplication(
            id: 501,
            bundleIdentifier: "com.example.Editor",
            name: "Editor",
            iconData: Data([0x01, 0x02])
        )
        let sameIdentity = MirageMedia.MirageApplication(
            id: 501,
            bundleIdentifier: "com.example.Editor",
            name: "Renamed",
            iconData: nil
        )
        let window = MirageMedia.MirageWindow(
            id: 9_001,
            title: "",
            application: app,
            frame: CGRect(x: 10, y: 20, width: 1_440, height: 900),
            isOnScreen: true,
            windowLayer: 0
        )

        let encoded = try JSONEncoder().encode(window.withTabCount(3))
        let decoded = try JSONDecoder().decode(MirageMedia.MirageWindow.self, from: encoded)

        #expect(app == sameIdentity)
        #expect(window.displayName == "Editor")
        #expect(decoded.id == 9_001)
        #expect(decoded.tabCount == 3)
        #expect(decoded.application?.iconData == Data([0x01, 0x02]))
    }
}
