//
//  HostCloudKitRegistrarCompatibilityTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/7/26.
//

import CloudKit
import Testing
@testable import MirageKitHost

@Suite("Host CloudKit registrar compatibility")
struct HostCloudKitRegistrarCompatibilityTests {
    @Test("Bootstrap metadata retry only applies to invalid-arguments failures")
    func bootstrapMetadataRetryOnlyAppliesToInvalidArgumentsFailures() {
        #expect(
            MirageHostCloudKitRegistrar.shouldRetryHostRegistrationWithoutBootstrapMetadata(
                error: CKError(.invalidArguments),
                attemptedBootstrapMetadataWrite: true
            )
        )
        #expect(
            MirageHostCloudKitRegistrar.shouldRetryHostRegistrationWithoutBootstrapMetadata(
                error: CKError(.invalidArguments),
                attemptedBootstrapMetadataWrite: false
            ) == false
        )
        #expect(
            MirageHostCloudKitRegistrar.shouldRetryHostRegistrationWithoutBootstrapMetadata(
                error: CKError(.networkFailure),
                attemptedBootstrapMetadataWrite: true
            ) == false
        )
    }

    @Test("Optional host metadata retry only applies to invalid-arguments failures")
    func optionalHostMetadataRetryOnlyAppliesToInvalidArgumentsFailures() {
        #expect(
            MirageHostCloudKitRegistrar.shouldRetryHostRegistrationWithoutOptionalHostMetadata(
                error: CKError(.invalidArguments),
                attemptedOptionalHostMetadataWrite: true
            )
        )
        #expect(
            MirageHostCloudKitRegistrar.shouldRetryHostRegistrationWithoutOptionalHostMetadata(
                error: CKError(.invalidArguments),
                attemptedOptionalHostMetadataWrite: false
            ) == false
        )
        #expect(
            MirageHostCloudKitRegistrar.shouldRetryHostRegistrationWithoutOptionalHostMetadata(
                error: CKError(.serverRejectedRequest),
                attemptedOptionalHostMetadataWrite: true
            ) == false
        )
    }

    @Test("Participant identity schema failures are ignored only for invalid arguments")
    func participantIdentitySchemaFailuresAreIgnoredOnlyForInvalidArguments() {
        #expect(
            MirageHostCloudKitRegistrar.shouldIgnoreParticipantIdentityRecordFailure(
                CKError(.invalidArguments)
            )
        )
        #expect(
            MirageHostCloudKitRegistrar.shouldIgnoreParticipantIdentityRecordFailure(
                CKError(.zoneBusy)
            ) == false
        )
    }

    @Test("Rich peer metadata retry only applies to invalid-arguments failures")
    func richPeerMetadataRetryOnlyAppliesToInvalidArgumentsFailures() {
        #expect(
            MirageHostCloudKitRegistrar.shouldRetryHostRegistrationWithMinimalRecordFields(
                error: CKError(.invalidArguments),
                attemptedRichPeerMetadataWrite: true
            )
        )
        #expect(
            MirageHostCloudKitRegistrar.shouldRetryHostRegistrationWithMinimalRecordFields(
                error: CKError(.invalidArguments),
                attemptedRichPeerMetadataWrite: false
            ) == false
        )
        #expect(
            MirageHostCloudKitRegistrar.shouldRetryHostRegistrationWithMinimalRecordFields(
                error: CKError(.networkFailure),
                attemptedRichPeerMetadataWrite: true
            ) == false
        )
    }

    @Test("Best-effort CloudKit lookup failures ignore only unknown-item errors")
    func bestEffortCloudKitLookupFailuresIgnoreOnlyUnknownItemErrors() {
        #expect(MirageHostCloudKitRegistrar.shouldIgnoreExistingHostRecordQueryFailure(CKError(.unknownItem)))
        #expect(MirageHostCloudKitRegistrar.shouldIgnoreStaleOwnHostsCleanupFailure(CKError(.unknownItem)))
        #expect(
            MirageHostCloudKitRegistrar.shouldIgnoreExistingHostRecordQueryFailure(CKError(.invalidArguments)) == false
        )
        #expect(
            MirageHostCloudKitRegistrar.shouldIgnoreStaleOwnHostsCleanupFailure(CKError(.networkFailure)) == false
        )
    }
}
