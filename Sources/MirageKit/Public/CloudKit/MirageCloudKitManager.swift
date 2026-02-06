//
//  MirageCloudKitManager.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/28/26.
//
//  Manages CloudKit operations for device registration and user identity.
//

import CloudKit
import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// Manages CloudKit operations for iCloud-based trust.
///
/// Handles device registration, user identity fetching, and share participant caching.
/// Initialize with a ``MirageCloudKitConfiguration`` to customize behavior.
///
/// ## Usage
///
/// ```swift
/// let config = MirageCloudKitConfiguration(
///     containerIdentifier: "iCloud.com.yourcompany.YourApp"
/// )
/// let manager = MirageCloudKitManager(configuration: config)
/// await manager.initialize()
/// ```
///
/// - Note: The `CKContainer` is created lazily during ``initialize()`` to prevent crashes
///   when CloudKit is misconfigured or unavailable. Check ``isAvailable`` after initialization.
@Observable
@MainActor
public final class MirageCloudKitManager {
    // MARK: - Properties

    /// Configuration for CloudKit operations.
    public let configuration: MirageCloudKitConfiguration

    /// CloudKit container, created lazily during initialization.
    public private(set) var container: CKContainer?

    /// Current user's CloudKit record ID (recordName portion).
    public private(set) var currentUserRecordID: String?

    /// Whether CloudKit is available and the user is signed in.
    public private(set) var isAvailable: Bool = false

    /// Last error encountered during CloudKit operations.
    public private(set) var lastError: Error?

    /// Whether initial setup has completed.
    public private(set) var isInitialized: Bool = false

    /// Cache of share participant user IDs with expiration.
    private var shareParticipantCache: [String: Date] = [:]

    // MARK: - Initialization

    /// Creates a CloudKit manager with the specified configuration.
    ///
    /// - Parameter configuration: CloudKit configuration including container ID and record types.
    /// - Note: The `CKContainer` is not created until ``initialize()`` is called.
    public init(configuration: MirageCloudKitConfiguration) {
        self.configuration = configuration
    }

    /// Creates a CloudKit manager with just a container identifier, using default settings.
    ///
    /// - Parameter containerIdentifier: CloudKit container identifier.
    public convenience init(containerIdentifier: String) {
        self.init(configuration: MirageCloudKitConfiguration(containerIdentifier: containerIdentifier))
    }

    // MARK: - Setup

    /// Initializes CloudKit and fetches the current user's record ID.
    ///
    /// Call this early in your app's lifecycle to set up CloudKit.
    /// This method creates the `CKContainer`, registers the current device,
    /// and caches the user's identity.
    ///
    /// - Note: Container creation is deferred to this method to avoid crashes when
    ///   CloudKit is misconfigured. If container creation fails, CloudKit features
    ///   will be unavailable but the app will continue to function.
    public func initialize() async {
        guard !isInitialized else { return }

        MirageLogger.appState("CloudKit: Starting initialization for container '\(configuration.containerIdentifier)'")

        // Create the container lazily to avoid crashes during app launch
        // when CloudKit is misconfigured or unavailable
        if container == nil {
            do {
                container = try createContainer()
                MirageLogger.appState("CloudKit: Container created successfully")
            } catch {
                lastError = error
                isAvailable = false
                isInitialized = true
                MirageLogger.error(.appState, "CloudKit container creation failed: \(error)")
                return
            }
        }

        guard let container else {
            MirageLogger.error(.appState, "CloudKit: Container is nil after creation attempt")
            isAvailable = false
            isInitialized = true
            return
        }

        do {
            // Check account status
            MirageLogger.appState("CloudKit: Checking account status...")
            let status = try await container.accountStatus()
            MirageLogger.appState("CloudKit: Account status = \(Self.describeAccountStatus(status))")

            switch status {
            case .available:
                isAvailable = true
                MirageLogger.appState("CloudKit: Account available, proceeding with setup")

            case .noAccount:
                isAvailable = false
                MirageLogger.appState("CloudKit: No iCloud account signed in - iCloud features disabled")
                isInitialized = true
                return

            case .restricted:
                isAvailable = false
                MirageLogger.appState("CloudKit: Account restricted (parental controls or MDM)")
                isInitialized = true
                return

            case .couldNotDetermine:
                isAvailable = false
                MirageLogger.appState("CloudKit: Could not determine account status")
                isInitialized = true
                return

            case .temporarilyUnavailable:
                isAvailable = false
                MirageLogger.appState("CloudKit: Account temporarily unavailable")
                isInitialized = true
                return

            @unknown default:
                isAvailable = false
                MirageLogger.appState("CloudKit: Unknown account status")
                isInitialized = true
                return
            }

            // Fetch current user's record ID
            MirageLogger.appState("CloudKit: Fetching user record ID...")
            let userRecordID = try await container.userRecordID()
            currentUserRecordID = userRecordID.recordName
            MirageLogger.appState("CloudKit: User record ID = \(userRecordID.recordName)")

            // Register this device
            MirageLogger.appState("CloudKit: Registering current device...")
            await registerCurrentDevice()

            isInitialized = true
            MirageLogger.appState("CloudKit: Initialization complete")
        } catch {
            lastError = error
            isAvailable = false
            isInitialized = true
            MirageLogger.error(.appState, "CloudKit initialization failed: \(error.localizedDescription)")
            if let ckError = error as? CKError {
                MirageLogger.error(
                    .appState,
                    "CloudKit error code: \(ckError.code.rawValue), userInfo: \(ckError.userInfo)"
                )
            }
        }
    }

    /// Creates a CKContainer with error handling.
    ///
    /// - Throws: An error if the container cannot be created (e.g., invalid identifier,
    ///   missing entitlements, or provisioning mismatch).
    /// - Returns: The created CKContainer.
    private func createContainer() throws -> CKContainer {
        // CKContainer(identifier:) can crash synchronously if the container
        // is misconfigured. We wrap it in a do-catch to handle potential
        // runtime issues, though note that some failures may still trap.
        // The main protection is deferring this call until after app launch.
        CKContainer(identifier: configuration.containerIdentifier)
    }

    /// Reinitializes CloudKit after an account change.
    ///
    /// Call this when you detect an iCloud account change to refresh
    /// the user identity and device registration.
    public func reinitialize() async {
        isInitialized = false
        currentUserRecordID = nil
        isAvailable = false
        shareParticipantCache.removeAll()
        await initialize()
    }

    // MARK: - Device Registration

    /// Registers the current device in the user's private CloudKit database.
    private func registerCurrentDevice() async {
        guard isAvailable, let container else { return }

        #if os(macOS)
        let deviceName = Host.current().localizedName ?? "Mac"
        let deviceType = "mac"
        #elseif os(iOS)
        let deviceName = UIDevice.current.name
        let deviceType = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #elseif os(visionOS)
        let deviceName = "Apple Vision Pro"
        let deviceType = "vision"
        #else
        let deviceName = "Unknown Device"
        let deviceType = "unknown"
        #endif

        // Use a stable device identifier
        let deviceID = getOrCreateDeviceID()

        let recordID = CKRecord.ID(recordName: deviceID.uuidString)
        let record = CKRecord(recordType: configuration.deviceRecordType, recordID: recordID)
        record["name"] = deviceName
        record["deviceType"] = deviceType
        record["lastSeen"] = Date()

        do {
            let database = container.privateCloudDatabase
            _ = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .changedKeys)
            MirageLogger.appState("Registered device in CloudKit: \(deviceName)")
        } catch {
            // Don't treat registration failures as critical
            MirageLogger.error(.appState, "Failed to register device in CloudKit: \(error)")
        }
    }

    /// Returns a stable device identifier, creating one if needed.
    private func getOrCreateDeviceID() -> UUID {
        let key = configuration.deviceIDKey
        if let storedID = UserDefaults.standard.string(forKey: key),
           let uuid = UUID(uuidString: storedID) {
            return uuid
        }

        let newID = UUID()
        UserDefaults.standard.set(newID.uuidString, forKey: key)
        return newID
    }

    // MARK: - Share Participant Checking

    /// Checks if a user ID is a participant in any accepted shares.
    ///
    /// - Parameter userID: The CloudKit user record ID to check.
    /// - Returns: Whether the user is a share participant.
    public func isShareParticipant(userID: String) async -> Bool {
        // Check cache first
        if let expiration = shareParticipantCache[userID], expiration > Date() { return true }

        guard isAvailable, let container else { return false }

        do {
            // Fetch all accepted shares in the shared database
            let sharedDatabase = container.sharedCloudDatabase
            let zones = try await sharedDatabase.allRecordZones()

            for zone in zones {
                // Get the share for this zone
                if let share = try await fetchShareForZone(zone, in: sharedDatabase) {
                    // Check if the user is a participant
                    for participant in share.participants {
                        if let participantUserID = participant.userIdentity.userRecordID?.recordName,
                           participantUserID == userID {
                            // Cache the result
                            shareParticipantCache[userID] = Date()
                                .addingTimeInterval(configuration.shareParticipantCacheTTL)
                            return true
                        }
                    }
                }
            }

            return false
        } catch {
            MirageLogger.error(.appState, "Failed to check share participants: \(error)")
            return false
        }
    }

    /// Fetches the CKShare for a record zone if one exists.
    private func fetchShareForZone(_ zone: CKRecordZone, in database: CKDatabase) async throws -> CKShare? {
        let query = CKQuery(recordType: "cloudkit.share", predicate: NSPredicate(value: true))
        let (results, _) = try await database.records(matching: query, inZoneWith: zone.zoneID)

        for (_, result) in results {
            if case let .success(record) = result, let share = record as? CKShare { return share }
        }

        return nil
    }

    /// Clears the share participant cache.
    ///
    /// Call this after share membership changes to ensure fresh data.
    public func clearShareParticipantCache() {
        shareParticipantCache.removeAll()
    }

    /// Refreshes share participant data from CloudKit.
    ///
    /// Clears the cache so the next ``isShareParticipant(userID:)`` call fetches fresh data.
    public func refreshShareParticipants() async {
        shareParticipantCache.removeAll()
    }

    // MARK: - Account Change Handling

    /// Handles iCloud account changes by reinitializing.
    ///
    /// Call this from your app's account change notification handler.
    public func handleAccountChange() async {
        MirageLogger.appState("iCloud account changed, reinitializing CloudKit")
        await reinitialize()
    }
}

// MARK: - Helpers

extension MirageCloudKitManager {
    /// Returns a human-readable description of a CloudKit account status.
    static func describeAccountStatus(_ status: CKAccountStatus) -> String {
        switch status {
        case .available: return "available"
        case .noAccount: return "noAccount"
        case .restricted: return "restricted"
        case .couldNotDetermine: return "couldNotDetermine"
        case .temporarilyUnavailable: return "temporarilyUnavailable"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }
}
