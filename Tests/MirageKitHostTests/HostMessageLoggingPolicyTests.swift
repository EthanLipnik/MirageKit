//
//  HostMessageLoggingPolicyTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

@testable import MirageKitHost
import MirageKit
import Testing

@Suite("Host Message Logging Policy")
struct HostMessageLoggingPolicyTests {
    @Test("Receiver media feedback is excluded from generic received-message logging")
    func receiverMediaFeedbackIsExcludedFromGenericReceivedMessageLogging() {
        #expect(!MirageHostService.shouldLogReceivedControlMessageType(.receiverMediaFeedback))
        #expect(MirageHostService.shouldLogReceivedControlMessageType(.ping))
    }
}
