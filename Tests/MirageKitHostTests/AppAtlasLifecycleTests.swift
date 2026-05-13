//
//  AppAtlasLifecycleTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/4/26.
//

#if os(macOS)
@testable import MirageKit
@testable import MirageKitHost
import CoreGraphics
import Testing

@Suite("App Atlas Lifecycle")
struct AppAtlasLifecycleTests {
    @Test("Auxiliary parent association prefers overlap then nearest center")
    func auxiliaryParentAssociationPrefersOverlapThenNearestCenter() {
        let streamID = MirageHostService.bestAuxiliaryParentStream(
            auxiliaryFrame: CGRect(x: 460, y: 120, width: 120, height: 80),
            visibleParents: [
                (streamID: 21, frame: CGRect(x: 0, y: 0, width: 400, height: 400)),
                (streamID: 22, frame: CGRect(x: 500, y: 0, width: 400, height: 400)),
            ]
        )
        let nearestStreamID = MirageHostService.bestAuxiliaryParentStream(
            auxiliaryFrame: CGRect(x: 420, y: 120, width: 40, height: 80),
            visibleParents: [
                (streamID: 31, frame: CGRect(x: 0, y: 0, width: 400, height: 400)),
                (streamID: 32, frame: CGRect(x: 500, y: 0, width: 400, height: 400)),
            ]
        )

        #expect(streamID == 22)
        #expect(nearestStreamID == 31)
    }
}
#endif
