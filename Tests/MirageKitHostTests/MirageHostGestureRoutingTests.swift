//
//  MirageHostGestureRoutingTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/4/26.
//

#if os(macOS)
@testable import MirageKitHost
import MirageKit
import Testing

@Suite("Host gesture routing")
struct MirageHostGestureRoutingTests {
    @Test("Horizontal swipes map to Space actions")
    func horizontalSwipesMapToSpaceActions() {
        #expect(MirageHostInputController.hostSystemAction(for: MirageSwipeEvent(
            deltaX: -1,
            deltaY: 0
        )) == .spaceRight)
        #expect(MirageHostInputController.hostSystemAction(for: MirageSwipeEvent(
            deltaX: 1,
            deltaY: 0
        )) == .spaceLeft)
    }

    @Test("Vertical swipes map to Mission Control actions")
    func verticalSwipesMapToMissionControlActions() {
        #expect(MirageHostInputController.hostSystemAction(for: MirageSwipeEvent(
            deltaX: 0,
            deltaY: 1
        )) == .missionControl)
        #expect(MirageHostInputController.hostSystemAction(for: MirageSwipeEvent(
            deltaX: 0,
            deltaY: -1
        )) == .appExpose)
    }
}
#endif
