//
//  MirageCloudKitHostProvider.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/28/26.
//
//  Fetches host information from CloudKit.
//

import CloudKit
import Foundation
import Observation

/// Fetches host information from CloudKit for display in the client.
///
/// This provider queries both:
/// - **Private database**: Hosts belonging to the same iCloud account (own hosts)
/// - **Shared database**: Hosts shared by friends via CKShare
///
/// ## Usage
///
/// ```swift
/// let provider = MirageCloudKitHostProvider(cloudKitManager: cloudKitManager)
/// await provider.fetchHosts()
///
/// // Access discovered hosts
/// let myHosts = provider.ownHosts
/// let friendHosts = provider.sharedHosts
/// ```
@Observable
@MainActor
public final class MirageCloudKitHostProvider {
    // MARK: - Properties

    /// Hosts from the user's own iCloud account.
    public private(set) var ownHosts: [MirageCloudKitHostInfo] = []

    /// Hosts shared by friends via CKShare.
    public private(set) var sharedHosts: [MirageCloudKitHostInfo] = []

    /// Whether a fetch operation is in progress.
    public private(set) var isLoading: Bool = false

    /// Last error from fetch operations.
    public private(set) var lastError: Error?

    /// CloudKit manager for container access.
    private let cloudKitManager: MirageCloudKitManager

    /// Zone ID for host records.
    private let hostZoneID: CKRecordZone.ID

    /// Background parser used to decode host records off the main actor.
    private let hostRecordParser = HostRecordSnapshotParser()

    // MARK: - Initialization

    /// Creates a host provider with the specified CloudKit manager.
    ///
    /// - Parameter cloudKitManager: The CloudKit manager providing container access.
    public init(cloudKitManager: MirageCloudKitManager) {
        self.cloudKitManager = cloudKitManager
        hostZoneID = CKRecordZone.ID(
            zoneName: cloudKitManager.configuration.hostZoneName,
            ownerName: CKCurrentUserDefaultName
        )
    }

    // MARK: - Fetching

    /// Fetches all hosts from both own and shared databases.
    ///
    /// Updates `ownHosts` and `sharedHosts` with the results.
    public func fetchHosts() async {
        guard cloudKitManager.isAvailable else {
            MirageLogger.appState("CloudKit unavailable, skipping host fetch")
            return
        }

        isLoading = true
        defer { isLoading = false }
        lastError = nil

        async let ownTask: () = refreshOwnHosts()
        async let sharedTask: () = refreshSharedHosts()

        await ownTask
        await sharedTask
    }

    /// Refreshes hosts from the user's private database.
    public func refreshOwnHosts() async {
        guard let container = cloudKitManager.container else { return }

        let database = container.privateCloudDatabase

        // Query all host records in the host zone
        let query = CKQuery(
            recordType: cloudKitManager.configuration.hostRecordType,
            predicate: NSPredicate(value: true)
        )

        do {
            let (results, _) = try await database.records(matching: query, inZoneWith: hostZoneID)

            var snapshots: [HostRecordSnapshot] = []
            var processedCount = 0
            for (_, result) in results {
                if case let .success(record) = result {
                    snapshots.append(snapshot(from: record, isShared: false, ownerUserID: nil))
                }
                processedCount += 1
                if processedCount.isMultiple(of: 25) {
                    await Task.yield()
                }
            }

            let hosts = await hostRecordParser.parse(snapshots)
            ownHosts = hosts.sorted { $0.name < $1.name }
            MirageLogger.appState("Fetched \(hosts.count) own hosts from CloudKit")
        } catch {
            MirageLogger.error(.appState, error: error, message: "Failed to fetch own hosts: ")
            lastError = error
        }
    }

    /// Refreshes hosts from shared database zones (friends' hosts).
    public func refreshSharedHosts() async {
        guard let container = cloudKitManager.container else { return }

        let sharedDatabase = container.sharedCloudDatabase

        do {
            // Get all shared zones
            let zones = try await sharedDatabase.allRecordZones()

            var snapshots: [HostRecordSnapshot] = []
            var processedCount = 0

            for zone in zones {
                // Query for host records in each shared zone
                let query = CKQuery(
                    recordType: cloudKitManager.configuration.hostRecordType,
                    predicate: NSPredicate(value: true)
                )

                do {
                    let (results, _) = try await sharedDatabase.records(matching: query, inZoneWith: zone.zoneID)

                    for (_, result) in results {
                        if case let .success(record) = result {
                            // Get owner user ID from the zone
                            let ownerUserID = zone.zoneID.ownerName
                            snapshots.append(snapshot(from: record, isShared: true, ownerUserID: ownerUserID))
                        }
                        processedCount += 1
                        if processedCount.isMultiple(of: 25) {
                            await Task.yield()
                        }
                    }
                } catch {
                    MirageLogger.error(.appState, error: error, message: "Failed to fetch hosts from zone \(zone.zoneID.zoneName): ")
                }
            }

            let hosts = await hostRecordParser.parse(snapshots)
            sharedHosts = hosts.sorted { $0.name < $1.name }
            MirageLogger.appState("Fetched \(hosts.count) shared hosts from CloudKit")
        } catch {
            MirageLogger.error(.appState, error: error, message: "Failed to enumerate shared zones: ")
            lastError = error
        }
    }

    // MARK: - Removal

    /// Removes an own host record from the private CloudKit database.
    ///
    /// - Parameter deviceID: Stable host device identifier.
    public func removeOwnHost(deviceID: UUID) async throws {
        guard let container = cloudKitManager.container else { throw MirageCloudKitError.containerUnavailable }

        let database = container.privateCloudDatabase
        let recordIDs = try await queryHostRecordIDs(
            database: database,
            zoneID: hostZoneID,
            deviceID: deviceID
        )

        if recordIDs.isEmpty {
            ownHosts.removeAll { $0.id == deviceID }
            return
        }

        _ = try await database.modifyRecords(
            saving: [],
            deleting: recordIDs
        )
        ownHosts.removeAll { $0.id == deviceID }
        MirageLogger.appState("Removed own CloudKit host record(s) for \(deviceID)")
    }

    /// Removes a shared host record from shared CloudKit zones.
    ///
    /// - Parameter deviceID: Stable host device identifier.
    public func removeSharedHost(deviceID: UUID) async throws {
        guard let container = cloudKitManager.container else { throw MirageCloudKitError.containerUnavailable }

        let database = container.sharedCloudDatabase
        let zones = try await database.allRecordZones()
        var deletedRecord = false

        for zone in zones {
            let recordIDs = try await queryHostRecordIDs(
                database: database,
                zoneID: zone.zoneID,
                deviceID: deviceID
            )
            guard !recordIDs.isEmpty else { continue }

            _ = try await database.modifyRecords(
                saving: [],
                deleting: recordIDs
            )
            deletedRecord = true
        }

        if !deletedRecord {
            throw MirageCloudKitHostProviderError.sharedHostNotFound(deviceID: deviceID)
        }

        sharedHosts.removeAll { $0.id == deviceID }
        MirageLogger.appState("Removed shared CloudKit host record(s) for \(deviceID)")
    }

    /// Removes a host based on ownership.
    /// - Parameter host: Host metadata to remove.
    public func removeHost(_ host: MirageCloudKitHostInfo) async throws {
        if host.isShared {
            try await removeSharedHost(deviceID: host.id)
        } else {
            try await removeOwnHost(deviceID: host.id)
        }
    }

    // MARK: - Parsing

    /// Captures a sendable snapshot of a CloudKit record for background parsing.
    private func snapshot(
        from record: CKRecord,
        isShared: Bool,
        ownerUserID: String?
    ) -> HostRecordSnapshot {
        HostRecordSnapshot(
            recordID: record.recordID.recordName,
            deviceIDString: record[MirageCloudKitHostInfo.RecordKey.deviceID.rawValue] as? String,
            name: record[MirageCloudKitHostInfo.RecordKey.name.rawValue] as? String,
            deviceTypeRawValue: record[MirageCloudKitHostInfo.RecordKey.deviceType.rawValue] as? String,
            maxFrameRate: (record[MirageCloudKitHostInfo.RecordKey.maxFrameRate.rawValue] as? Int64).map(Int.init),
            supportsHEVC: (record[MirageCloudKitHostInfo.RecordKey.supportsHEVC.rawValue] as? Int64).map { $0 != 0 },
            supportsP3: (record[MirageCloudKitHostInfo.RecordKey.supportsP3.rawValue] as? Int64).map { $0 != 0 },
            maxStreams: (record[MirageCloudKitHostInfo.RecordKey.maxStreams.rawValue] as? Int64).map(Int.init),
            protocolVersion: (record[MirageCloudKitHostInfo.RecordKey.protocolVersion.rawValue] as? Int64).map(Int.init),
            identityKeyID: record[MirageCloudKitHostInfo.RecordKey.identityKeyID.rawValue] as? String,
            identityPublicKey: record[MirageCloudKitHostInfo.RecordKey.identityPublicKey.rawValue] as? Data,
            hardwareModelIdentifier: record[MirageCloudKitHostInfo.RecordKey.hardwareModelIdentifier.rawValue] as? String,
            hardwareIconName: record[MirageCloudKitHostInfo.RecordKey.hardwareIconName.rawValue] as? String,
            hardwareMachineFamily: record[MirageCloudKitHostInfo.RecordKey.hardwareMachineFamily.rawValue] as? String,
            remoteEnabled: (record[MirageCloudKitHostInfo.RecordKey.remoteEnabled.rawValue] as? Int64).map { $0 != 0 },
            bootstrapMetadataBlob: record[MirageCloudKitHostInfo.RecordKey.bootstrapMetadataBlob.rawValue] as? Data,
            lastSeen: record[MirageCloudKitHostInfo.RecordKey.lastSeen.rawValue] as? Date,
            modificationDate: record.modificationDate,
            ownerUserID: ownerUserID,
            isShared: isShared
        )
    }

    private func queryHostRecordIDs(
        database: CKDatabase,
        zoneID: CKRecordZone.ID,
        deviceID: UUID
    ) async throws -> [CKRecord.ID] {
        let query = CKQuery(
            recordType: cloudKitManager.configuration.hostRecordType,
            predicate: NSPredicate(
                format: "%K == %@",
                MirageCloudKitHostInfo.RecordKey.deviceID.rawValue,
                deviceID.uuidString
            )
        )

        let (results, _) = try await database.records(matching: query, inZoneWith: zoneID)
        var recordIDs: [CKRecord.ID] = []
        for (_, result) in results {
            if case let .success(record) = result {
                recordIDs.append(record.recordID)
            }
        }

        return recordIDs
    }
}

private struct HostRecordSnapshot: Sendable {
    let recordID: String
    let deviceIDString: String?
    let name: String?
    let deviceTypeRawValue: String?
    let maxFrameRate: Int?
    let supportsHEVC: Bool?
    let supportsP3: Bool?
    let maxStreams: Int?
    let protocolVersion: Int?
    let identityKeyID: String?
    let identityPublicKey: Data?
    let hardwareModelIdentifier: String?
    let hardwareIconName: String?
    let hardwareMachineFamily: String?
    let remoteEnabled: Bool?
    let bootstrapMetadataBlob: Data?
    let lastSeen: Date?
    let modificationDate: Date?
    let ownerUserID: String?
    let isShared: Bool
}

private actor HostRecordSnapshotParser {
    func parse(_ snapshots: [HostRecordSnapshot]) -> [MirageCloudKitHostInfo] {
        snapshots.compactMap(parseHostRecord)
    }

    private func parseHostRecord(_ snapshot: HostRecordSnapshot) -> MirageCloudKitHostInfo? {
        guard let rawDeviceID = snapshot.deviceIDString,
              let deviceID = UUID(uuidString: rawDeviceID) else {
            MirageLogger.appState("Skipping host record with invalid deviceID: \(snapshot.recordID)")
            return nil
        }

        let deviceType = DeviceType(rawValue: snapshot.deviceTypeRawValue ?? "mac") ?? .mac
        let bootstrapMetadata = snapshot.bootstrapMetadataBlob.flatMap {
            try? JSONDecoder().decode(MirageBootstrapMetadata.self, from: $0)
        }
        let capabilities = MirageHostCapabilities(
            maxStreams: snapshot.maxStreams ?? 4,
            supportsHEVC: snapshot.supportsHEVC ?? true,
            supportsP3ColorSpace: snapshot.supportsP3 ?? true,
            maxFrameRate: snapshot.maxFrameRate ?? 120,
            protocolVersion: snapshot.protocolVersion ?? Int(MirageKit.protocolVersion),
            deviceID: deviceID,
            identityKeyID: snapshot.identityKeyID,
            hardwareModelIdentifier: snapshot.hardwareModelIdentifier,
            hardwareIconName: snapshot.hardwareIconName,
            hardwareMachineFamily: snapshot.hardwareMachineFamily
        )

        return MirageCloudKitHostInfo(
            id: deviceID,
            name: snapshot.name ?? "Unknown Host",
            deviceType: deviceType,
            capabilities: capabilities,
            lastSeen: snapshot.lastSeen ?? snapshot.modificationDate ?? Date.distantPast,
            ownerUserID: snapshot.ownerUserID,
            isShared: snapshot.isShared,
            recordID: snapshot.recordID,
            identityKeyID: snapshot.identityKeyID,
            identityPublicKey: snapshot.identityPublicKey,
            remoteEnabled: snapshot.remoteEnabled ?? false,
            bootstrapMetadata: bootstrapMetadata
        )
    }
}

public enum MirageCloudKitHostProviderError: LocalizedError, Sendable {
    case sharedHostNotFound(deviceID: UUID)

    public var errorDescription: String? {
        switch self {
        case let .sharedHostNotFound(deviceID):
            "Shared host \(deviceID.uuidString) was not found in accepted CloudKit shares."
        }
    }
}
