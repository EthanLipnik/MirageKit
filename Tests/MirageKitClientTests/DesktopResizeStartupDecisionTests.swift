//
//  DesktopResizeStartupDecisionTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/6/26.
//

@testable import MirageKitClient
import Testing

@Suite("Desktop Resize Startup Decision")
struct DesktopResizeStartupDecisionTests {
    @Test("Desktop resize flow is deferred until first presentation")
    func defersUntilFirstPresentation() {
        #expect(desktopResizeStartupDecision(hasPresentedFrame: false) == .deferUntilFirstPresentation)
    }

    @Test("Desktop resize flow is allowed after first presentation")
    func allowsResizeFlowAfterFirstPresentation() {
        #expect(desktopResizeStartupDecision(hasPresentedFrame: true) == .allowResizeFlow)
    }
}
