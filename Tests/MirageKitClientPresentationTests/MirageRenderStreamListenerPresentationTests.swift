//
//  MirageRenderStreamListenerPresentationTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/5/26.
//

@testable import MirageKitClientPresentation
import Testing

@Suite("Render Stream Listeners")
struct MirageRenderStreamListenerPresentationTests {
    @Test("Weak owner clears when listener owner deallocates")
    func weakOwnerClearsWhenListenerOwnerDeallocates() {
        var owner: ListenerOwner? = ListenerOwner()
        let weakOwner = MirageRenderStreamWeakOwner(owner!)

        #expect(weakOwner.value != nil)
        owner = nil
        #expect(weakOwner.value == nil)
    }

    @Test("Frame listener preserves weak owner and callback")
    func frameListenerPreservesWeakOwnerAndCallback() {
        let owner = ListenerOwner()
        let counter = CallbackCounter()
        let listener = MirageRenderStreamFrameListener(
            owner: MirageRenderStreamWeakOwner(owner),
            callback: {
                counter.count += 1
            }
        )

        #expect(listener.owner.value === owner)
        listener.callback()
        #expect(counter.count == 1)
    }
}

private final class ListenerOwner {}

private final class CallbackCounter: @unchecked Sendable {
    var count = 0
}
