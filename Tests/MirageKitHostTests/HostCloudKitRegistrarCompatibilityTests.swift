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
}
