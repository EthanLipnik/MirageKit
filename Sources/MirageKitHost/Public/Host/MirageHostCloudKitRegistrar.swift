//
//  MirageHostCloudKitRegistrar.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/5/26.
//

import CloudKit
import Foundation
import MirageKit

#if os(macOS)
/// Serializes host-registration CloudKit traffic away from the main actor.
public actor MirageHostCloudKitRegistrar {
    public struct RegistrationRequest: Sendable {
        public let deviceID: UUID
        public let name: String
        public let advertisement: LoomPeerAdvertisement
        public let identityKeyID: String?
        public let identityPublicKey: Data?
        public let remoteEnabled: Bool
        public let bootstrapMetadata: LoomBootstrapMetadata?

        public init(
            deviceID: UUID,
            name: String,
            advertisement: LoomPeerAdvertisement,
            identityKeyID: String? = nil,
            identityPublicKey: Data? = nil,
            remoteEnabled: Bool = false,
            bootstrapMetadata: LoomBootstrapMetadata? = nil
        ) {
            self.deviceID = deviceID
            self.name = name
            self.advertisement = advertisement
            self.identityKeyID = identityKeyID
            self.identityPublicKey = identityPublicKey
            self.remoteEnabled = remoteEnabled
            self.bootstrapMetadata = bootstrapMetadata
        }
    }

    private let configuration: LoomCloudKitConfiguration
    private let peerZoneID: CKRecordZone.ID
    private var peerRecordName: String?
    private var cloudKitSchemaSupportsBootstrapMetadata = true
    private var cloudKitSchemaSupportsOptionalPeerMetadata = true
    private var cloudKitSchemaSupportsRichPeerMetadata = true
    private var cloudKitSchemaSupportsParticipantIdentityRecords = true

    private struct PeerRecordPopulationAttempt {
        let attemptedOptionalPeerMetadataWrite: Bool
        let attemptedRichPeerMetadataWrite: Bool
    }

    public init(configuration: LoomCloudKitConfiguration) {
        self.configuration = configuration
        peerZoneID = CKRecordZone.ID(
            zoneName: configuration.peerZoneName,
            ownerName: CKCurrentUserDefaultName
        )
    }

    public func cleanupStaleOwnHosts(
        currentDeviceID: UUID,
        currentHostName: String,
        currentIdentityKeyID: String?
    ) async throws -> Int {
        guard let currentIdentityKeyID else { return 0 }

        let database = container.privateCloudDatabase
        let query = CKQuery(
            recordType: configuration.peerRecordType,
            predicate: NSPredicate(value: true)
        )

        let results: [(CKRecord.ID, Result<CKRecord, Error>)]
        do {
            let queryResult = try await database.records(matching: query, inZoneWith: peerZoneID)
            results = queryResult.0
        } catch where Self.shouldIgnoreStaleOwnHostsCleanupFailure(error) {
            MirageLogger.appState(
                "Skipping stale CloudKit host cleanup because the host record zone is not yet available"
            )
            return 0
        }

        let normalizedCurrentName = normalizeHostName(currentHostName)
        var staleRecordIDs: [CKRecord.ID] = []

        for (_, result) in results {
            guard case let .success(record) = result else { continue }

            let recordDeviceID = parseRecordDeviceID(record)
            guard let recordDeviceID,
                  recordDeviceID != currentDeviceID else { continue }

            let advertisementBlob = record[LoomCloudKitPeerInfo.RecordKey.advertisementBlob.rawValue] as? Data
            let advertisement = advertisementBlob.flatMap {
                try? JSONDecoder().decode(LoomPeerAdvertisement.self, from: $0)
            }
            guard advertisement?.identityKeyID == currentIdentityKeyID else { continue }

            let recordName = (record[LoomCloudKitPeerInfo.RecordKey.name.rawValue] as? String) ?? ""
            guard normalizeHostName(recordName) == normalizedCurrentName else { continue }

            staleRecordIDs.append(record.recordID)
        }

        guard !staleRecordIDs.isEmpty else { return 0 }

        _ = try await database.modifyRecords(
            saving: [],
            deleting: staleRecordIDs
        )
        return staleRecordIDs.count
    }

    public func registerHost(_ request: RegistrationRequest) async throws {
        let database = container.privateCloudDatabase
        let zone = CKRecordZone(zoneID: peerZoneID)
        do {
            _ = try await database.modifyRecordZones(saving: [zone], deleting: [])
        } catch {
            MirageLogger.appState("Host registrar zone creation returned: \(error.localizedDescription)")
        }

        while true {
            let record = try await fetchOrCreatePeerRecord(
                deviceID: request.deviceID,
                database: database
            )
            let populationAttempt = populate(record: record, from: request)

            do {
                try await persistPeerRecord(
                    record,
                    database: database,
                    identityKeyID: request.identityKeyID,
                    identityPublicKey: request.identityPublicKey
                )
                return
            } catch where Self.shouldRetryHostRegistrationWithoutBootstrapMetadata(
                error: error,
                attemptedBootstrapMetadataWrite: cloudKitSchemaSupportsBootstrapMetadata && request.bootstrapMetadata != nil
            ) {
                cloudKitSchemaSupportsBootstrapMetadata = false
                MirageLogger.appState(
                    "CloudKit schema rejected bootstrapMetadataBlob; retrying host registration without bootstrap metadata"
                )
            } catch where Self.shouldRetryHostRegistrationWithoutOptionalHostMetadata(
                error: error,
                attemptedOptionalHostMetadataWrite: populationAttempt.attemptedOptionalPeerMetadataWrite
            ) {
                cloudKitSchemaSupportsOptionalPeerMetadata = false
                MirageLogger.appState(
                    "CloudKit schema rejected optional peer metadata; retrying host registration with base fields only"
                )
            } catch where Self.shouldRetryHostRegistrationWithMinimalRecordFields(
                error: error,
                attemptedRichPeerMetadataWrite: populationAttempt.attemptedRichPeerMetadataWrite
            ) {
                cloudKitSchemaSupportsRichPeerMetadata = false
                MirageLogger.appState(
                    "CloudKit schema rejected rich peer metadata; retrying host registration with minimal legacy fields"
                )
            }
        }
    }

    public func updateLastSeen() async {
        let database = container.privateCloudDatabase
        let cachedRecord: CKRecord?
        do {
            cachedRecord = try await fetchCachedPeerRecord(database: database)
        } catch {
            return
        }
        guard let record = cachedRecord else { return }

        record[LoomCloudKitPeerInfo.RecordKey.lastSeen.rawValue] = Date()

        do {
            _ = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .changedKeys)
        } catch {
            if Self.isUnknownItemCloudKitError(error) {
                peerRecordName = nil
                MirageLogger.appState("Skipping lastSeen update because the cached CloudKit host record no longer exists")
                return
            }
            MirageLogger.error(.appState, error: error, message: "Failed to update lastSeen: ")
        }
    }

    private var container: CKContainer {
        CKContainer(identifier: configuration.containerIdentifier)
    }

    private func fetchOrCreatePeerRecord(
        deviceID: UUID,
        database: CKDatabase
    ) async throws -> CKRecord {
        if let cachedRecord = try await fetchCachedPeerRecord(database: database) {
            return cachedRecord
        }

        let predicate = NSPredicate(format: "deviceID == %@", deviceID.uuidString)
        let query = CKQuery(recordType: configuration.peerRecordType, predicate: predicate)

        do {
            let (results, _) = try await database.records(matching: query, inZoneWith: peerZoneID)
            for (_, result) in results {
                if case let .success(record) = result {
                    peerRecordName = record.recordID.recordName
                    return record
                }
            }
        } catch where Self.shouldIgnoreExistingHostRecordQueryFailure(error) {
            MirageLogger.appState("Existing host record lookup missed in CloudKit; creating a replacement record")
        } catch {
            MirageLogger.error(.appState, error: error, message: "Failed to query existing host record: ")
        }

        let recordID = CKRecord.ID(recordName: deviceID.uuidString, zoneID: peerZoneID)
        let record = CKRecord(recordType: configuration.peerRecordType, recordID: recordID)
        peerRecordName = recordID.recordName
        return record
    }

    private func fetchCachedPeerRecord(database: CKDatabase) async throws -> CKRecord? {
        guard let peerRecordName else { return nil }
        let recordID = CKRecord.ID(recordName: peerRecordName, zoneID: peerZoneID)

        do {
            return try await database.record(for: recordID)
        } catch {
            if shouldResetCachedHostRecordName(for: error) {
                self.peerRecordName = nil
                return nil
            }
            throw error
        }
    }

    @discardableResult
    private func populate(record: CKRecord, from request: RegistrationRequest) -> PeerRecordPopulationAttempt {
        record[LoomCloudKitPeerInfo.RecordKey.deviceID.rawValue] = request.deviceID.uuidString
        record[LoomCloudKitPeerInfo.RecordKey.name.rawValue] = request.name
        let attemptedRichPeerMetadataWrite = cloudKitSchemaSupportsRichPeerMetadata
        if attemptedRichPeerMetadataWrite {
            record[LoomCloudKitPeerInfo.RecordKey.deviceType.rawValue] = (request.advertisement.deviceType ?? .mac).rawValue
            record[LoomCloudKitPeerInfo.RecordKey.advertisementBlob.rawValue] = try? JSONEncoder().encode(request.advertisement)
        } else {
            record[LoomCloudKitPeerInfo.RecordKey.deviceType.rawValue] = nil
            record[LoomCloudKitPeerInfo.RecordKey.advertisementBlob.rawValue] = nil
        }
        let attemptedOptionalPeerMetadataWrite = cloudKitSchemaSupportsOptionalPeerMetadata
        if cloudKitSchemaSupportsOptionalPeerMetadata {
            record[LoomCloudKitPeerInfo.RecordKey.identityPublicKey.rawValue] = request.identityPublicKey
            record[LoomCloudKitPeerInfo.RecordKey.remoteAccessEnabled.rawValue] = request.remoteEnabled ? 1 : 0
        } else {
            record[LoomCloudKitPeerInfo.RecordKey.identityPublicKey.rawValue] = nil
            record[LoomCloudKitPeerInfo.RecordKey.remoteAccessEnabled.rawValue] = nil
        }
        if cloudKitSchemaSupportsBootstrapMetadata {
            if let bootstrapMetadata = request.bootstrapMetadata {
                record[LoomCloudKitPeerInfo.RecordKey.bootstrapMetadataBlob.rawValue] = try? JSONEncoder().encode(bootstrapMetadata)
            } else {
                record[LoomCloudKitPeerInfo.RecordKey.bootstrapMetadataBlob.rawValue] = nil
            }
        }
        record[LoomCloudKitPeerInfo.RecordKey.lastSeen.rawValue] = Date()
        return PeerRecordPopulationAttempt(
            attemptedOptionalPeerMetadataWrite: attemptedOptionalPeerMetadataWrite,
            attemptedRichPeerMetadataWrite: attemptedRichPeerMetadataWrite
        )
    }

    private func persistPeerRecord(
        _ record: CKRecord,
        database: CKDatabase,
        identityKeyID: String?,
        identityPublicKey: Data?
    ) async throws {
        let (saveResults, _) = try await database.modifyRecords(
            saving: [record],
            deleting: [],
            savePolicy: .changedKeys
        )
        if let savedRecord = try saveResults[record.recordID]?.get() {
            peerRecordName = savedRecord.recordID.recordName
            MirageLogger.appState("Registered peer in CloudKit: \(savedRecord.recordID.recordName)")
        }
        if cloudKitSchemaSupportsParticipantIdentityRecords,
           let identityKeyID,
           let identityPublicKey {
            do {
                try await upsertParticipantIdentityRecord(
                    keyID: identityKeyID,
                    publicKey: identityPublicKey,
                    database: database
                )
            } catch where Self.shouldIgnoreParticipantIdentityRecordFailure(error) {
                cloudKitSchemaSupportsParticipantIdentityRecords = false
                MirageLogger.appState(
                    "CloudKit schema rejected MirageParticipantIdentity records; continuing without participant identity metadata"
                )
            }
        }
    }

    private func upsertParticipantIdentityRecord(
        keyID: String,
        publicKey: Data,
        database: CKDatabase
    ) async throws {
        let recordID = CKRecord.ID(
            recordName: "identity-\(keyID)",
            zoneID: peerZoneID
        )
        let record = CKRecord(
            recordType: configuration.participantIdentityRecordType,
            recordID: recordID
        )
        record["keyID"] = keyID
        record["publicKey"] = publicKey
        record["lastSeen"] = Date()

        _ = try await database.modifyRecords(
            saving: [record],
            deleting: [],
            savePolicy: .changedKeys
        )
    }

    nonisolated static func shouldRetryHostRegistrationWithoutBootstrapMetadata(
        error: Error,
        attemptedBootstrapMetadataWrite: Bool
    ) -> Bool {
        attemptedBootstrapMetadataWrite && isInvalidArgumentsCloudKitError(error)
    }

    nonisolated static func shouldRetryHostRegistrationWithoutOptionalHostMetadata(
        error: Error,
        attemptedOptionalHostMetadataWrite: Bool
    ) -> Bool {
        attemptedOptionalHostMetadataWrite && isInvalidArgumentsCloudKitError(error)
    }

    nonisolated static func shouldIgnoreParticipantIdentityRecordFailure(_ error: Error) -> Bool {
        isInvalidArgumentsCloudKitError(error)
    }

    nonisolated static func shouldRetryHostRegistrationWithMinimalRecordFields(
        error: Error,
        attemptedRichPeerMetadataWrite: Bool
    ) -> Bool {
        attemptedRichPeerMetadataWrite && isInvalidArgumentsCloudKitError(error)
    }

    nonisolated static func shouldIgnoreExistingHostRecordQueryFailure(_ error: Error) -> Bool {
        isUnknownItemCloudKitError(error)
    }

    nonisolated static func shouldIgnoreStaleOwnHostsCleanupFailure(_ error: Error) -> Bool {
        isUnknownItemCloudKitError(error)
    }

    nonisolated static func isInvalidArgumentsCloudKitError(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == CKError.errorDomain else { return false }
        return nsError.code == CKError.Code.invalidArguments.rawValue
    }

    nonisolated static func isUnknownItemCloudKitError(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == CKError.errorDomain else { return false }
        return nsError.code == CKError.Code.unknownItem.rawValue
    }

    private func shouldResetCachedHostRecordName(for error: Error) -> Bool {
        Self.isUnknownItemCloudKitError(error)
    }

    private func normalizeHostName(_ name: String) -> String {
        name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseRecordDeviceID(_ record: CKRecord) -> UUID? {
        if let rawDeviceID = record[LoomCloudKitPeerInfo.RecordKey.deviceID.rawValue] as? String,
           let deviceID = UUID(uuidString: rawDeviceID) {
            return deviceID
        }

        return UUID(uuidString: record.recordID.recordName)
    }
}
#endif
