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
        public let capabilities: MirageHostCapabilities
        public let identityKeyID: String?
        public let identityPublicKey: Data?
        public let remoteEnabled: Bool
        public let bootstrapMetadata: MirageBootstrapMetadata?

        public init(
            deviceID: UUID,
            name: String,
            capabilities: MirageHostCapabilities,
            identityKeyID: String? = nil,
            identityPublicKey: Data? = nil,
            remoteEnabled: Bool = false,
            bootstrapMetadata: MirageBootstrapMetadata? = nil
        ) {
            self.deviceID = deviceID
            self.name = name
            self.capabilities = capabilities
            self.identityKeyID = identityKeyID
            self.identityPublicKey = identityPublicKey
            self.remoteEnabled = remoteEnabled
            self.bootstrapMetadata = bootstrapMetadata
        }
    }

    private let configuration: MirageCloudKitConfiguration
    private let hostZoneID: CKRecordZone.ID
    private var hostRecordName: String?
    private var cloudKitSchemaSupportsBootstrapMetadata = true
    private var cloudKitSchemaSupportsOptionalHostMetadata = true
    private var cloudKitSchemaSupportsParticipantIdentityRecords = true

    public init(configuration: MirageCloudKitConfiguration) {
        self.configuration = configuration
        hostZoneID = CKRecordZone.ID(
            zoneName: configuration.hostZoneName,
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
            recordType: configuration.hostRecordType,
            predicate: NSPredicate(value: true)
        )

        let (results, _) = try await database.records(matching: query, inZoneWith: hostZoneID)
        let normalizedCurrentName = normalizeHostName(currentHostName)
        var staleRecordIDs: [CKRecord.ID] = []

        for (_, result) in results {
            guard case let .success(record) = result else { continue }

            let recordDeviceID = parseRecordDeviceID(record)
            guard let recordDeviceID,
                  recordDeviceID != currentDeviceID else { continue }

            let recordIdentityKeyID = record[MirageCloudKitHostInfo.RecordKey.identityKeyID.rawValue] as? String
            guard recordIdentityKeyID == currentIdentityKeyID else { continue }

            let recordName = (record[MirageCloudKitHostInfo.RecordKey.name.rawValue] as? String) ?? ""
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
        let zone = CKRecordZone(zoneID: hostZoneID)
        do {
            _ = try await database.modifyRecordZones(saving: [zone], deleting: [])
        } catch {
            MirageLogger.appState("Host registrar zone creation returned: \(error.localizedDescription)")
        }

        while true {
            let record = try await fetchOrCreateHostRecord(
                deviceID: request.deviceID,
                database: database
            )
            let attemptedOptionalHostMetadataWrite = populate(record: record, from: request)

            do {
                try await persistHostRecord(
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
                attemptedOptionalHostMetadataWrite: attemptedOptionalHostMetadataWrite
            ) {
                cloudKitSchemaSupportsOptionalHostMetadata = false
                MirageLogger.appState(
                    "CloudKit schema rejected optional host metadata; retrying host registration with base fields only"
                )
            }
        }
    }

    public func updateLastSeen() async {
        let database = container.privateCloudDatabase
        let cachedRecord: CKRecord?
        do {
            cachedRecord = try await fetchCachedHostRecord(database: database)
        } catch {
            return
        }
        guard let record = cachedRecord else { return }

        record[MirageCloudKitHostInfo.RecordKey.lastSeen.rawValue] = Date()

        do {
            _ = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .changedKeys)
        } catch {
            MirageLogger.error(.appState, error: error, message: "Failed to update lastSeen: ")
        }
    }

    private var container: CKContainer {
        CKContainer(identifier: configuration.containerIdentifier)
    }

    private func fetchOrCreateHostRecord(
        deviceID: UUID,
        database: CKDatabase
    ) async throws -> CKRecord {
        if let cachedRecord = try await fetchCachedHostRecord(database: database) {
            return cachedRecord
        }

        let predicate = NSPredicate(format: "deviceID == %@", deviceID.uuidString)
        let query = CKQuery(recordType: configuration.hostRecordType, predicate: predicate)

        do {
            let (results, _) = try await database.records(matching: query, inZoneWith: hostZoneID)
            for (_, result) in results {
                if case let .success(record) = result {
                    hostRecordName = record.recordID.recordName
                    return record
                }
            }
        } catch {
            MirageLogger.error(.appState, error: error, message: "Failed to query existing host record: ")
        }

        let recordID = CKRecord.ID(recordName: deviceID.uuidString, zoneID: hostZoneID)
        let record = CKRecord(recordType: configuration.hostRecordType, recordID: recordID)
        record[MirageCloudKitHostInfo.RecordKey.createdAt.rawValue] = Date()
        hostRecordName = recordID.recordName
        return record
    }

    private func fetchCachedHostRecord(database: CKDatabase) async throws -> CKRecord? {
        guard let hostRecordName else { return nil }
        let recordID = CKRecord.ID(recordName: hostRecordName, zoneID: hostZoneID)

        do {
            return try await database.record(for: recordID)
        } catch {
            if shouldResetCachedHostRecordName(for: error) {
                self.hostRecordName = nil
                return nil
            }
            throw error
        }
    }

    @discardableResult
    private func populate(record: CKRecord, from request: RegistrationRequest) -> Bool {
        record[MirageCloudKitHostInfo.RecordKey.deviceID.rawValue] = request.deviceID.uuidString
        record[MirageCloudKitHostInfo.RecordKey.name.rawValue] = request.name
        record[MirageCloudKitHostInfo.RecordKey.deviceType.rawValue] = DeviceType.mac.rawValue
        record[MirageCloudKitHostInfo.RecordKey.maxFrameRate.rawValue] = Int64(request.capabilities.maxFrameRate)
        record[MirageCloudKitHostInfo.RecordKey.supportsHEVC.rawValue] = request.capabilities.supportsHEVC ? 1 : 0
        record[MirageCloudKitHostInfo.RecordKey.supportsP3.rawValue] = request.capabilities.supportsP3ColorSpace ? 1 : 0
        record[MirageCloudKitHostInfo.RecordKey.maxStreams.rawValue] = Int64(request.capabilities.maxStreams)
        record[MirageCloudKitHostInfo.RecordKey.protocolVersion.rawValue] = Int64(request.capabilities.protocolVersion)
        if cloudKitSchemaSupportsOptionalHostMetadata {
            record[MirageCloudKitHostInfo.RecordKey.identityKeyID.rawValue] = request.identityKeyID
            record[MirageCloudKitHostInfo.RecordKey.identityPublicKey.rawValue] = request.identityPublicKey
            record[MirageCloudKitHostInfo.RecordKey.hardwareModelIdentifier.rawValue] = request.capabilities.hardwareModelIdentifier
            record[MirageCloudKitHostInfo.RecordKey.hardwareIconName.rawValue] = request.capabilities.hardwareIconName
            record[MirageCloudKitHostInfo.RecordKey.hardwareMachineFamily.rawValue] = request.capabilities.hardwareMachineFamily
            record[MirageCloudKitHostInfo.RecordKey.remoteEnabled.rawValue] = request.remoteEnabled ? 1 : 0
        }
        if cloudKitSchemaSupportsBootstrapMetadata {
            if let bootstrapMetadata = request.bootstrapMetadata {
                record[MirageCloudKitHostInfo.RecordKey.bootstrapMetadataBlob.rawValue] = try? JSONEncoder().encode(bootstrapMetadata)
            } else {
                record[MirageCloudKitHostInfo.RecordKey.bootstrapMetadataBlob.rawValue] = nil
            }
        }
        record[MirageCloudKitHostInfo.RecordKey.lastSeen.rawValue] = Date()
        return cloudKitSchemaSupportsOptionalHostMetadata
    }

    private func persistHostRecord(
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
            hostRecordName = savedRecord.recordID.recordName
            MirageLogger.appState("Registered host in CloudKit: \(savedRecord.recordID.recordName)")
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
            zoneID: hostZoneID
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

    nonisolated static func isInvalidArgumentsCloudKitError(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == CKError.errorDomain else { return false }
        return nsError.code == CKError.Code.invalidArguments.rawValue
    }

    private func shouldResetCachedHostRecordName(for error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == CKError.errorDomain else { return false }
        return nsError.code == CKError.Code.unknownItem.rawValue
    }

    private func normalizeHostName(_ name: String) -> String {
        name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseRecordDeviceID(_ record: CKRecord) -> UUID? {
        if let rawDeviceID = record[MirageCloudKitHostInfo.RecordKey.deviceID.rawValue] as? String,
           let deviceID = UUID(uuidString: rawDeviceID) {
            return deviceID
        }

        return UUID(uuidString: record.recordID.recordName)
    }
}
#endif
