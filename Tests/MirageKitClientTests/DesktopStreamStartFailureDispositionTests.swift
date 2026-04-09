//
//  DesktopStreamStartFailureDispositionTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/10/26.
//

@testable import MirageKit
@testable import MirageKitClient
import Testing

#if os(macOS)
@Suite("Desktop Stream Start Failure Disposition")
struct DesktopStreamStartFailureDispositionTests {
    @Test("Virtual-display startup failures clear a pending desktop start")
    @MainActor
    func virtualDisplayStartFailureClearsPendingDesktopStart() throws {
        let service = MirageClientService(deviceName: "Test Device")
        service.connectionState = .connected(host: "Host")
        service.desktopStreamMode = .unified
        service.desktopStreamRequestStartTime = 42
        service.pendingDesktopRequestedColorDepth = .pro

        let error = ErrorMessage(
            code: .virtualDisplayStartFailed,
            message: "Failed to start desktop stream"
        )
        let envelope = try ControlMessage(type: .error, content: error)
        service.handleErrorMessage(envelope)

        #expect(service.connectionState == .connected(host: "Host"))
        #expect(service.desktopStreamMode == nil)
        #expect(service.desktopStreamRequestStartTime == 0)
        #expect(service.pendingDesktopRequestedColorDepth == nil)
    }

    @Test("Unrelated control errors keep active desktop state intact")
    @MainActor
    func unrelatedControlErrorsKeepActiveDesktopState() throws {
        let service = MirageClientService(deviceName: "Test Device")
        service.connectionState = .connected(host: "Host")
        service.desktopStreamID = 9
        service.desktopStreamMode = .secondary
        service.desktopStreamRequestStartTime = 77

        let error = ErrorMessage(
            code: .encodingError,
            message: "Encoder update failed"
        )
        let envelope = try ControlMessage(type: .error, content: error)
        service.handleErrorMessage(envelope)

        #expect(service.desktopStreamID == 9)
        #expect(service.desktopStreamMode == .secondary)
        #expect(service.desktopStreamRequestStartTime == 77)
    }
}
#endif
