//
//  ScrollPhysicsCapturingViewTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/3/26.
//

#if os(iOS) || os(visionOS)
@testable import MirageKitClient
import Testing
import UIKit

@MainActor
@Suite("Scroll physics view configuration")
struct ScrollPhysicsCapturingViewTests {
    @Test("Embedded scroll views keep their own pan delegates and touch types")
    func embeddedScrollViewsKeepTheirOwnPanDelegatesAndTouchTypes() {
        let view = ScrollPhysicsCapturingView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let scrollViews = view.subviews.compactMap { $0 as? UIScrollView }

        #expect(scrollViews.count == 2)

        let directTouchType = Int(UITouch.TouchType.direct.rawValue)
        let indirectPointerTouchType = Int(UITouch.TouchType.indirectPointer.rawValue)
        let indirectTouchType = Int(UITouch.TouchType.indirect.rawValue)
        let pencilTouchType = Int(UITouch.TouchType.pencil.rawValue)

        let directScrollView = try #require(
            scrollViews.first { allowedTouchTypes(for: $0).contains(directTouchType) }
        )
        let indirectScrollView = try #require(
            scrollViews.first { allowedTouchTypes(for: $0).contains(indirectPointerTouchType) }
        )

        #expect((directScrollView.panGestureRecognizer.delegate as AnyObject?) === directScrollView)
        #expect((indirectScrollView.panGestureRecognizer.delegate as AnyObject?) === indirectScrollView)

        #expect(allowedTouchTypes(for: directScrollView) == [directTouchType])
        #expect(allowedTouchTypes(for: indirectScrollView) == [indirectPointerTouchType, indirectTouchType])
        #expect(!allowedTouchTypes(for: directScrollView).contains(pencilTouchType))
    }

    private func allowedTouchTypes(for scrollView: UIScrollView) -> Set<Int> {
        Set((scrollView.panGestureRecognizer.allowedTouchTypes ?? []).map(\.intValue))
    }
}
#endif
