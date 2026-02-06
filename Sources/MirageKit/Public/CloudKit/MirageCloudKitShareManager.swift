//
//  MirageCloudKitShareManager.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/28/26.
//
//  Manages CloudKit sharing for friend access to host.
//

import CloudKit
import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Manages CloudKit sharing for allowing friends to connect to a host.
///
/// Creates and manages CKShare records that allow other iCloud users
/// to connect without manual approval.
///
/// ## Usage
///
/// ```swift
/// let shareManager = MirageCloudKitShareManager(cloudKitManager: cloudKitManager)
/// await shareManager.setup()
///
/// // Present sharing UI (macOS)
/// try await shareManager.presentSharingUI(from: window)
///
/// // Or create sharing controller (iOS/visionOS)
/// let controller = try await shareManager.createSharingController()
/// ```
@Observable
@MainActor
public final class MirageCloudKitShareManager {
    // MARK: - Properties

    /// CloudKit manager for container access.
    private let cloudKitManager: MirageCloudKitManager

    /// Current active share for this host, if any.
    public private(set) var activeShare: CKShare?

    /// Host record used as the root for sharing.
    public private(set) var hostRecord: CKRecord?

    /// Whether share operations are in progress.
    public private(set) var isLoading: Bool = false

    /// Last error from share operations.
    public private(set) var lastError: Error?

    /// Custom zone for host records.
    private let hostZoneID: CKRecordZone.ID

    // MARK: - Initialization

    /// Creates a share manager with the specified CloudKit manager.
    ///
    /// - Parameter cloudKitManager: The CloudKit manager providing container access.
    public init(cloudKitManager: MirageCloudKitManager) {
        self.cloudKitManager = cloudKitManager
        hostZoneID = CKRecordZone.ID(
            zoneName: cloudKitManager.configuration.hostZoneName,
            ownerName: CKCurrentUserDefaultName
        )
    }

    // MARK: - Setup

    /// Ensures the host zone exists and fetches any existing host record and share.
    ///
    /// Call this after the CloudKit manager is initialized to set up sharing.
    public func setup() async {
        MirageLogger.appState("ShareManager: Starting setup...")

        guard cloudKitManager.isAvailable else {
            MirageLogger.appState("ShareManager: Skipping setup - CloudKit not available (isAvailable=false)")
            return
        }

        guard let container = cloudKitManager.container else {
            MirageLogger.appState("ShareManager: Skipping setup - CloudKit container is nil")
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            // Create zone if needed
            MirageLogger.appState("ShareManager: Creating zone '\(hostZoneID.zoneName)'...")
            let zone = CKRecordZone(zoneID: hostZoneID)
            let (savedZones, _) = try await container.privateCloudDatabase.modifyRecordZones(
                saving: [zone],
                deleting: []
            )
            MirageLogger.appState("ShareManager: Zone creation result - saved \(savedZones.count) zones")

            // Fetch existing host record
            MirageLogger.appState("ShareManager: Fetching existing host record...")
            await fetchHostRecord()

            // Fetch existing share if host record exists
            if let hostRecord {
                MirageLogger.appState("ShareManager: Found host record, fetching share...")
                await fetchShare(for: hostRecord)
            } else {
                MirageLogger.appState("ShareManager: No existing host record found")
            }

            MirageLogger.appState("ShareManager: Setup complete")
        } catch {
            lastError = error
            MirageLogger.error(.appState, "ShareManager: Failed to setup: \(error.localizedDescription)")
            if let ckError = error as? CKError {
                MirageLogger.error(
                    .appState,
                    "ShareManager: CKError code=\(ckError.code.rawValue), userInfo=\(ckError.userInfo)"
                )
            }
        }
    }

    // MARK: - Host Record Management

    /// Fetches or creates the host record.
    private func fetchHostRecord() async {
        guard let container = cloudKitManager.container else { return }

        let database = container.privateCloudDatabase

        // Query for existing host record
        let query = CKQuery(
            recordType: cloudKitManager.configuration.hostRecordType,
            predicate: NSPredicate(value: true)
        )

        do {
            let (results, _) = try await database.records(matching: query, inZoneWith: hostZoneID)

            for (_, result) in results {
                if case let .success(record) = result {
                    hostRecord = record
                    MirageLogger.appState("Found existing host record")
                    return
                }
            }

            // No existing record - will create when sharing
            MirageLogger.appState("No existing host record found")
        } catch {
            MirageLogger.error(.appState, "Failed to fetch host record: \(error)")
        }
    }

    /// Creates a new host record for sharing.
    private func createHostRecord() async throws -> CKRecord {
        guard let container = cloudKitManager.container else { throw MirageCloudKitError.containerUnavailable }

        let database = container.privateCloudDatabase

        #if os(macOS)
        let hostName = Host.current().localizedName ?? "Mac"
        #else
        let hostName = "My Mac"
        #endif

        let recordID = CKRecord.ID(recordName: UUID().uuidString, zoneID: hostZoneID)
        let record = CKRecord(recordType: cloudKitManager.configuration.hostRecordType, recordID: recordID)
        record["name"] = hostName
        record["createdAt"] = Date()

        let (saveResults, _) = try await database.modifyRecords(saving: [record], deleting: [])

        guard let savedRecord = try saveResults[recordID]?.get() else { throw MirageCloudKitError.recordNotSaved }

        hostRecord = savedRecord
        MirageLogger.appState("Created new host record: \(hostName)")
        return savedRecord
    }

    // MARK: - Host Registration

    /// Registers or updates the host in CloudKit with full metadata.
    ///
    /// Call this when the host app launches to ensure the host record
    /// is up-to-date with current name, capabilities, and last-seen time.
    ///
    /// - Parameters:
    ///   - deviceID: Stable device identifier.
    ///   - name: Display name for the host.
    ///   - capabilities: Host capabilities (HEVC, frame rate, etc.).
    public func registerHost(
        deviceID: UUID,
        name: String,
        capabilities: MirageHostCapabilities
    )
    async throws {
        MirageLogger.appState("ShareManager: registerHost called for '\(name)' (deviceID: \(deviceID))")

        guard cloudKitManager.isAvailable else {
            MirageLogger.appState("ShareManager: Skipping host registration - CloudKit not available")
            return
        }

        guard let container = cloudKitManager.container else {
            MirageLogger.appState("ShareManager: Skipping host registration - container is nil")
            return
        }

        let database = container.privateCloudDatabase

        // First ensure zone exists
        MirageLogger.appState("ShareManager: Ensuring zone '\(hostZoneID.zoneName)' exists...")
        let zone = CKRecordZone(zoneID: hostZoneID)
        do {
            let (savedZones, _) = try await database.modifyRecordZones(saving: [zone], deleting: [])
            MirageLogger.appState("ShareManager: Zone save successful - \(savedZones.count) zones saved")
        } catch {
            // Zone may already exist, continue
            MirageLogger.appState("ShareManager: Zone creation returned: \(error.localizedDescription)")
            if let ckError = error as? CKError { MirageLogger.appState("ShareManager: CKError code=\(ckError.code.rawValue)") }
        }

        // Query for existing host record with this device ID
        let predicate = NSPredicate(format: "deviceID == %@", deviceID.uuidString)
        let query = CKQuery(
            recordType: cloudKitManager.configuration.hostRecordType,
            predicate: predicate
        )

        var existingRecord: CKRecord?
        do {
            let (results, _) = try await database.records(matching: query, inZoneWith: hostZoneID)
            for (_, result) in results {
                if case let .success(record) = result {
                    existingRecord = record
                    break
                }
            }
        } catch {
            MirageLogger.error(.appState, "Failed to query existing host record: \(error)")
        }

        // Create or update record
        let record: CKRecord
        if let existing = existingRecord { record = existing } else {
            let recordID = CKRecord.ID(recordName: deviceID.uuidString, zoneID: hostZoneID)
            record = CKRecord(recordType: cloudKitManager.configuration.hostRecordType, recordID: recordID)
            record[MirageCloudKitHostInfo.RecordKey.createdAt.rawValue] = Date()
        }

        // Update all fields
        record[MirageCloudKitHostInfo.RecordKey.deviceID.rawValue] = deviceID.uuidString
        record[MirageCloudKitHostInfo.RecordKey.name.rawValue] = name
        record[MirageCloudKitHostInfo.RecordKey.deviceType.rawValue] = DeviceType.mac.rawValue
        record[MirageCloudKitHostInfo.RecordKey.maxFrameRate.rawValue] = Int64(capabilities.maxFrameRate)
        record[MirageCloudKitHostInfo.RecordKey.supportsHEVC.rawValue] = capabilities.supportsHEVC ? 1 : 0
        record[MirageCloudKitHostInfo.RecordKey.supportsP3.rawValue] = capabilities.supportsP3ColorSpace ? 1 : 0
        record[MirageCloudKitHostInfo.RecordKey.maxStreams.rawValue] = Int64(capabilities.maxStreams)
        record[MirageCloudKitHostInfo.RecordKey.protocolVersion.rawValue] = Int64(capabilities.protocolVersion)
        record[MirageCloudKitHostInfo.RecordKey.lastSeen.rawValue] = Date()

        do {
            let (saveResults, _) = try await database.modifyRecords(
                saving: [record],
                deleting: [],
                savePolicy: .changedKeys
            )
            if let savedRecord = try saveResults[record.recordID]?.get() {
                hostRecord = savedRecord
                MirageLogger.appState("Registered host in CloudKit: \(name)")
            }
        } catch {
            MirageLogger.error(.appState, "Failed to register host in CloudKit: \(error)")
            throw error
        }
    }

    /// Updates the last-seen timestamp for the host record.
    ///
    /// Call this periodically while the host is running to keep the record fresh.
    public func updateLastSeen() async {
        guard let record = hostRecord, let container = cloudKitManager.container else { return }

        record[MirageCloudKitHostInfo.RecordKey.lastSeen.rawValue] = Date()

        do {
            let database = container.privateCloudDatabase
            _ = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .changedKeys)
            MirageLogger.appState("Updated host lastSeen timestamp")
        } catch {
            MirageLogger.error(.appState, "Failed to update lastSeen: \(error)")
        }
    }

    // MARK: - Share Management

    /// Fetches the share for a host record.
    private func fetchShare(for record: CKRecord) async {
        guard let shareReference = record.share else {
            MirageLogger.appState("Host record has no share")
            return
        }

        guard let container = cloudKitManager.container else { return }

        do {
            let database = container.privateCloudDatabase
            let share = try await database.record(for: shareReference.recordID) as? CKShare
            activeShare = share
            MirageLogger.appState("Found existing share with \(share?.participants.count ?? 0) participants")
        } catch {
            MirageLogger.error(.appState, "Failed to fetch share: \(error)")
        }
    }

    /// Creates a new share for the host.
    ///
    /// - Returns: The created share, ready for presenting sharing UI.
    public func createShare() async throws -> CKShare {
        guard let container = cloudKitManager.container else { throw MirageCloudKitError.containerUnavailable }

        isLoading = true
        defer { isLoading = false }

        // Get or create host record
        let record: CKRecord = if let existing = hostRecord {
            existing
        } else {
            try await createHostRecord()
        }

        // Create share
        let share = CKShare(rootRecord: record)
        share[CKShare.SystemFieldKey.title] = cloudKitManager.configuration.shareTitle
        share.publicPermission = .none // Participants only

        // Save both record and share
        let database = container.privateCloudDatabase
        _ = try await database.modifyRecords(saving: [record, share], deleting: [])

        activeShare = share
        MirageLogger.appState("Created new share for host")
        return share
    }

    /// Revokes an existing share.
    ///
    /// This removes access for all participants.
    public func revokeShare() async throws {
        guard let share = activeShare else { return }
        guard let container = cloudKitManager.container else { throw MirageCloudKitError.containerUnavailable }

        isLoading = true
        defer { isLoading = false }

        let database = container.privateCloudDatabase
        _ = try await database.modifyRecords(saving: [], deleting: [share.recordID])

        activeShare = nil
        MirageLogger.appState("Revoked host share")
    }

    /// Removes a specific participant from the share.
    ///
    /// - Parameter participant: The participant to remove.
    public func removeParticipant(_ participant: CKShare.Participant) async throws {
        guard let share = activeShare else { return }
        guard let container = cloudKitManager.container else { throw MirageCloudKitError.containerUnavailable }

        share.removeParticipant(participant)

        let database = container.privateCloudDatabase
        _ = try await database.modifyRecords(saving: [share], deleting: [])

        MirageLogger.appState("Removed participant from share")

        // Refresh the CloudKit manager's cache
        cloudKitManager.clearShareParticipantCache()
    }

    // MARK: - Share UI Presentation

    #if os(macOS)
    /// Presents the sharing UI on macOS.
    ///
    /// - Parameter window: The window to present from.
    public func presentSharingUI(from _: NSWindow) async throws {
        guard let container = cloudKitManager.container else { throw MirageCloudKitError.containerUnavailable }

        let share: CKShare = if let existing = activeShare {
            existing
        } else {
            try await createShare()
        }

        guard hostRecord != nil else { throw MirageCloudKitError.noHostRecord }

        let sharingService = NSSharingService(named: .cloudSharing)
        let itemProvider = NSItemProvider()
        itemProvider.registerCloudKitShare(share, container: container)

        // Present the sharing service picker
        if let sharingService { sharingService.perform(withItems: [itemProvider]) }
    }
    #endif

    #if os(iOS) || os(visionOS)
    /// Creates a UICloudSharingController for presenting sharing UI on iOS/visionOS.
    ///
    /// - Returns: A configured sharing controller ready for presentation.
    public func createSharingController() async throws -> UICloudSharingController {
        guard let container = cloudKitManager.container else { throw MirageCloudKitError.containerUnavailable }

        let share: CKShare = if let existing = activeShare {
            existing
        } else {
            try await createShare()
        }

        guard hostRecord != nil else { throw MirageCloudKitError.noHostRecord }

        let controller = UICloudSharingController(share: share, container: container)
        controller.availablePermissions = [.allowReadWrite]

        return controller
    }
    #endif

    // MARK: - Share Acceptance

    /// Handles acceptance of a share from another user.
    ///
    /// Call this from your app's share acceptance handler (e.g., `userDidAcceptCloudKitShare`).
    ///
    /// - Parameter metadata: The share metadata from the URL.
    public func acceptShare(_ metadata: CKShare.Metadata) async throws {
        guard let container = cloudKitManager.container else { throw MirageCloudKitError.containerUnavailable }

        try await container.accept(metadata)
        MirageLogger.appState("Accepted share from \(metadata.ownerIdentity.nameComponents?.formatted() ?? "unknown")")

        // Refresh participant cache
        cloudKitManager.clearShareParticipantCache()
    }
}

// MARK: - Errors

/// Errors specific to CloudKit sharing operations.
public enum MirageCloudKitError: LocalizedError, Sendable {
    /// Failed to save record to CloudKit.
    case recordNotSaved

    /// No host record available for sharing.
    case noHostRecord

    /// Share not found.
    case shareNotFound

    /// CloudKit container is not available.
    case containerUnavailable

    public var errorDescription: String? {
        switch self {
        case .recordNotSaved:
            "Failed to save record to CloudKit"
        case .noHostRecord:
            "No host record available for sharing"
        case .shareNotFound:
            "Share not found"
        case .containerUnavailable:
            "CloudKit is not available"
        }
    }
}
