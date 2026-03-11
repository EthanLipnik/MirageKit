//
//  MirageHostCloudKitSharingCoordinator.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/11/26.
//

#if os(macOS)
import AppKit
import CloudKit
import Foundation
import MirageKit
import Observation

@Observable
@MainActor
public final class MirageHostCloudKitSharingCoordinator {
    public private(set) var activeShare: CKShare?
    public private(set) var hasPeerRecord = false
    public private(set) var isLoading = false
    public private(set) var lastError: Error?

    private let cloudKitManager: LoomCloudKitManager
    private let loadRegisteredPeerRecord: () async throws -> CKRecord?
    private let fetchRecord: (CKRecord.ID) async throws -> CKRecord
    private let saveRecords: ([CKRecord]) async throws -> [CKRecord.ID: Result<CKRecord, Error>]

    public init(
        cloudKitManager: LoomCloudKitManager,
        registrar: MirageHostCloudKitRegistrar
    ) {
        self.cloudKitManager = cloudKitManager
        loadRegisteredPeerRecord = {
            try await registrar.fetchRegisteredPeerRecord()
        }
        fetchRecord = { recordID in
            guard let container = cloudKitManager.container else {
                throw LoomCloudKitError.containerUnavailable
            }
            return try await container.privateCloudDatabase.record(for: recordID)
        }
        saveRecords = { records in
            guard let container = cloudKitManager.container else {
                throw LoomCloudKitError.containerUnavailable
            }
            let (saveResults, _) = try await container.privateCloudDatabase.modifyRecords(
                saving: records,
                deleting: []
            )
            return saveResults
        }
    }

    init(
        cloudKitManager: LoomCloudKitManager,
        loadRegisteredPeerRecord: @escaping () async throws -> CKRecord?,
        fetchRecord: @escaping (CKRecord.ID) async throws -> CKRecord,
        saveRecords: @escaping ([CKRecord]) async throws -> [CKRecord.ID: Result<CKRecord, Error>]
    ) {
        self.cloudKitManager = cloudKitManager
        self.loadRegisteredPeerRecord = loadRegisteredPeerRecord
        self.fetchRecord = fetchRecord
        self.saveRecords = saveRecords
    }

    public func refresh() async {
        isLoading = true
        defer { isLoading = false }

        lastError = nil

        do {
            guard let peerRecord = try await loadRegisteredPeerRecord() else {
                hasPeerRecord = false
                activeShare = nil
                return
            }

            hasPeerRecord = true
            activeShare = try await fetchShare(for: peerRecord)
        } catch {
            hasPeerRecord = false
            activeShare = nil
            lastError = error
            MirageLogger.error(.appState, error: error, message: "Failed to refresh host share state: ")
        }
    }

    @discardableResult
    public func ensureShare() async throws -> CKShare {
        isLoading = true
        defer { isLoading = false }

        lastError = nil

        do {
            guard let peerRecord = try await loadRegisteredPeerRecord() else {
                hasPeerRecord = false
                activeShare = nil
                throw LoomCloudKitError.noPeerRecord
            }

            hasPeerRecord = true

            if let existingShare = try await fetchShare(for: peerRecord) {
                activeShare = existingShare
                return existingShare
            }

            let share = CKShare(rootRecord: peerRecord)
            share[CKShare.SystemFieldKey.title] = cloudKitManager.configuration.shareTitle
            share.publicPermission = .none

            let saveResults = try await saveRecords([peerRecord, share])
            guard let savedShare = try saveResults[share.recordID]?.get() as? CKShare else {
                throw LoomCloudKitError.shareNotFound
            }

            activeShare = savedShare
            return savedShare
        } catch {
            lastError = error
            throw error
        }
    }

    public func presentSharingUI(from _: NSWindow) async throws {
        guard let container = cloudKitManager.container else {
            throw LoomCloudKitError.containerUnavailable
        }

        let share = try await ensureShare()
        let itemProvider = NSItemProvider()
        itemProvider.registerCloudKitShare(share, container: container)
        NSSharingService(named: .cloudSharing)?.perform(withItems: [itemProvider])
    }

    private func fetchShare(for record: CKRecord) async throws -> CKShare? {
        guard let shareReference = record.share else { return nil }
        return try await fetchRecord(shareReference.recordID) as? CKShare
    }
}
#endif
