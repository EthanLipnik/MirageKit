//
//  RenderTriggerCoalescingTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/13/26.
//

@testable import MirageKitClient
import Testing

#if os(macOS)
@Suite("Render Trigger Coalescing")
struct RenderTriggerCoalescingTests {
    @Test("Request while pending arms one follow-up signal")
    func pendingRequestArmsResignal() {
        var state = MirageClientRenderTrigger.CoalescingState()

        let firstDispatch = state.handleRequest()
        #expect(firstDispatch)
        #expect(state.pending)
        #expect(!state.resignalNeeded)

        let coalescedDispatch = state.handleRequest()
        #expect(!coalescedDispatch)
        #expect(state.pending)
        #expect(state.resignalNeeded)

        let followUpDispatch = state.handleCompletion()
        #expect(followUpDispatch)
        #expect(state.pending)
        #expect(!state.resignalNeeded)

        let finalDispatch = state.handleCompletion()
        #expect(!finalDispatch)
        #expect(!state.pending)
    }
}
#endif
