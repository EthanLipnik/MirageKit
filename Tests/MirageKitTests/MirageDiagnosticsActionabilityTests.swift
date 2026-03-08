//
//  MirageDiagnosticsActionabilityTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/3/26.
//
//  Ensures diagnostics filtering prefers typed error metadata over message parsing.
//

@testable import MirageKit
import Foundation
import Testing

@Suite("Mirage Diagnostics Actionability")
struct MirageDiagnosticsActionabilityTests {
    @Test("Typed NSURLError metadata is filtered")
    func typedURLErrorMetadataIsFiltered() {
        let event = makeEvent(
            message: "Socket dropped",
            metadata: MirageDiagnosticsErrorMetadata(
                typeName: "NSError",
                domain: NSURLErrorDomain,
                code: -1009
            )
        )

        #expect(MirageDiagnosticsActionability.shouldCaptureNonFatal(event) == false)
    }

    @Test("Typed VideoToolbox BadData metadata is filtered")
    func typedDecoderBadDataMetadataIsFiltered() {
        let event = makeEvent(
            message: "Decode callback failed",
            metadata: MirageDiagnosticsErrorMetadata(
                typeName: "NSError",
                domain: NSOSStatusErrorDomain,
                code: -12909
            )
        )

        #expect(MirageDiagnosticsActionability.shouldCaptureNonFatal(event) == false)
    }

    @Test("Typed VideoToolbox reference-missing metadata is filtered")
    func typedDecoderReferenceMissingMetadataIsFiltered() {
        let event = makeEvent(
            message: "Decode callback failed",
            metadata: MirageDiagnosticsErrorMetadata(
                typeName: "NSError",
                domain: NSOSStatusErrorDomain,
                code: -17694
            )
        )

        #expect(MirageDiagnosticsActionability.shouldCaptureNonFatal(event) == false)
    }

    @Test("Typed Cocoa decode metadata is filtered")
    func typedCocoaDecodeMetadataIsFiltered() {
        let event = makeEvent(
            message: "Failed to decode app list request",
            metadata: MirageDiagnosticsErrorMetadata(
                typeName: "Swift.DecodingError",
                domain: NSCocoaErrorDomain,
                code: 4865
            )
        )

        #expect(MirageDiagnosticsActionability.shouldCaptureNonFatal(event) == false)
    }

    @Test("Typed ScreenCaptureKit teardown metadata is filtered")
    func typedScreenCaptureKitTeardownMetadataIsFiltered() {
        let event = makeEvent(
            message: "Error stopping capture",
            metadata: MirageDiagnosticsErrorMetadata(
                typeName: "NSError",
                domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain",
                code: -3808
            )
        )

        #expect(MirageDiagnosticsActionability.shouldCaptureNonFatal(event) == false)
    }

    @Test("Typed metadata ignores message text")
    func typedMetadataIgnoresMessageText() {
        let event = makeEvent(
            message: "network is down",
            metadata: MirageDiagnosticsErrorMetadata(
                typeName: "NSError",
                domain: "com.mirage.tests",
                code: 777
            )
        )

        #expect(MirageDiagnosticsActionability.shouldCaptureNonFatal(event))
    }

    @Test("Typed runtime condition metadata is filtered")
    func typedRuntimeConditionMetadataIsFiltered() {
        let event = makeEvent(
            message: "ignored",
            metadata: MirageDiagnosticsErrorMetadata(error: MirageRuntimeConditionError.sessionLocked)
        )

        #expect(MirageDiagnosticsActionability.shouldCaptureNonFatal(event) == false)
    }

    @Test("Events without metadata are captured")
    func eventsWithoutMetadataAreCaptured() {
        let event = makeEvent(
            message: "The Internet connection appears to be offline",
            metadata: nil
        )

        #expect(MirageDiagnosticsActionability.shouldCaptureNonFatal(event))
    }

    @Test("Fault severity is always captured")
    func faultSeverityAlwaysCaptured() {
        let event = MirageDiagnosticsErrorEvent(
            date: Date(),
            category: .client,
            severity: .fault,
            source: .logger,
            message: "fatal",
            fileID: #fileID,
            line: #line,
            function: #function,
            metadata: nil
        )

        #expect(MirageDiagnosticsActionability.shouldCaptureNonFatal(event))
    }

    @Test("Host virtual-display fallback messages are filtered without metadata")
    func hostVirtualDisplayFallbackMessagesAreFilteredWithoutMetadata() {
        let event = makeEvent(
            message: "Virtual display failed Retina activation for all descriptor profiles",
            metadata: nil,
            category: .host
        )

        #expect(MirageDiagnosticsActionability.shouldCaptureNonFatal(event) == false)
    }

    @Test("Host virtual-display fail-closed messages are filtered without metadata")
    func hostVirtualDisplayFailClosedMessagesAreFilteredWithoutMetadata() {
        let event = makeEvent(
            message: "Virtual display acquisition failed for desktop stream; fail-closed policy active: creationFailed(\"Virtual display failed activation\")",
            metadata: nil,
            category: .host
        )

        #expect(MirageDiagnosticsActionability.shouldCaptureNonFatal(event) == false)
    }

    @Test("Remote signaling auth failures are filtered even with typed metadata")
    func remoteSignalingAuthFailuresAreFilteredEvenWithTypedMetadata() {
        let event = makeEvent(
            message: "Remote signaling close failed: http(statusCode: 401, errorCode: Optional(\"app_auth_failed\"), detail: Optional(\"app_signature_verification_failed\"))",
            metadata: MirageDiagnosticsErrorMetadata(
                typeName: "MirageKit.MirageRemoteSignalingError",
                domain: "MirageKit.MirageRemoteSignalingError",
                code: 0
            ),
            category: .appState
        )

        #expect(MirageDiagnosticsActionability.shouldCaptureNonFatal(event) == false)
    }

    @Test("Remote signaling invalid configuration metadata is filtered")
    func remoteSignalingInvalidConfigurationMetadataIsFiltered() {
        let event = makeEvent(
            message: "Remote signaling configuration is invalid",
            metadata: MirageDiagnosticsErrorMetadata(
                typeName: "MirageKit.MirageRemoteSignalingError",
                domain: "MirageKit.MirageRemoteSignalingError",
                code: 1
            ),
            category: .appState
        )

        #expect(MirageDiagnosticsActionability.shouldCaptureNonFatal(event) == false)
    }

    @Test("Bootstrap daemon permission failures are filtered without metadata")
    func bootstrapDaemonPermissionFailuresAreFilteredWithoutMetadata() {
        let event = makeEvent(
            message: "Bootstrap daemon register failed for com.ethanlipnik.Mirage.HostBootstrapDaemon.plist: The operation couldn’t be completed. Operation not permitted",
            metadata: nil,
            category: .bootstrapHandoff
        )

        #expect(MirageDiagnosticsActionability.shouldCaptureNonFatal(event) == false)
    }

    @Test("AppState virtual-display protocol errors are filtered without metadata")
    func appStateVirtualDisplayProtocolErrorsAreFilteredWithoutMetadata() {
        let event = makeEvent(
            message: "Client error: protocolError(\"Failed to start desktop stream: Protocol error: Virtual display acquisition failed for desktop stream\")",
            metadata: nil,
            category: .appState
        )

        #expect(MirageDiagnosticsActionability.shouldCaptureNonFatal(event) == false)
    }

    private func makeEvent(
        message: String,
        metadata: MirageDiagnosticsErrorMetadata?,
        category: LogCategory = .network
    ) -> MirageDiagnosticsErrorEvent {
        MirageDiagnosticsErrorEvent(
            date: Date(),
            category: category,
            severity: .error,
            source: .logger,
            message: message,
            fileID: #fileID,
            line: #line,
            function: #function,
            metadata: metadata
        )
    }
}
