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

    @Test("Production schema rejection for MiragePeer is classified explicitly")
    func productionSchemaRejectionForMiragePeerIsClassifiedExplicitly() {
        let error = NSError(
            domain: CKError.errorDomain,
            code: CKError.Code.serverRejectedRequest.rawValue,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Error saving record <CKRecordID: 0x1; recordName=test, zoneID=MiragePeerZone:__defaultOwner__> to server: Cannot create new type MiragePeer in production schema"
            ]
        )

        #expect(
            MirageHostCloudKitRegistrar.isMissingProductionSchemaRecordTypeError(
                error,
                recordType: "MiragePeer"
            )
        )
        #expect(
            MirageHostCloudKitRegistrar.isMissingProductionSchemaRecordTypeError(
                error,
                recordType: "MirageParticipantIdentity"
            ) == false
        )
    }

    @Test("Production schema rejection for CloudKit sharing is classified explicitly")
    func productionSchemaRejectionForCloudKitSharingIsClassifiedExplicitly() {
        let error = NSError(
            domain: CKError.errorDomain,
            code: CKError.Code.serverRejectedRequest.rawValue,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Error saving record <CKRecordID: 0x1; recordName=Share-test, zoneID=MiragePeerZone:__defaultOwner__> to server: Cannot create new type cloudkit.share in production schema"
            ]
        )

        #expect(MirageHostCloudKitRegistrar.isMissingProductionSchemaShareRecordError(error))
        #expect(
            MirageHostCloudKitRegistrar.isMissingProductionSchemaRecordTypeError(
                error,
                recordType: "MiragePeer"
            ) == false
        )
    }
}
