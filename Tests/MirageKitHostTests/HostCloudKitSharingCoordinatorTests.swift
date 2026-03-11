//
//  HostCloudKitSharingCoordinatorTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/11/26.
//

import CloudKit
import Testing
import MirageKit
@testable import MirageKitHost

@Suite("Host CloudKit sharing coordinator")
struct HostCloudKitSharingCoordinatorTests {
    @Test("Registrar caches the exact registered peer record ID")
    func registrarCachesTheExactRegisteredPeerRecordID() async {
        let configuration = MirageKit.makeCloudKitConfiguration(
            containerIdentifier: "iCloud.com.ethanlipnik.Mirage"
        )
        let registrar = MirageHostCloudKitRegistrar(configuration: configuration)

        let result = await registrar.storeRegisteredPeerRecordName("peer-record")
        let recordID = await registrar.registeredPeerRecordID()

        #expect(result.peerRecordName == "peer-record")
        #expect(recordID?.recordName == "peer-record")
        #expect(recordID?.zoneID.zoneName == configuration.peerZoneName)
    }

    @MainActor
    @Test("ensureShare creates a share for the loaded registered peer record")
    func ensureShareCreatesAShareForTheLoadedRegisteredPeerRecord() async throws {
        let configuration = MirageKit.makeCloudKitConfiguration(
            containerIdentifier: "iCloud.com.ethanlipnik.Mirage"
        )
        let cloudKitManager = LoomCloudKitManager(configuration: configuration)
        let peerRecord = makePeerRecord(configuration: configuration, recordName: "peer-record")
        let tracker = CloudKitSharingTracker()
        let coordinator = MirageHostCloudKitSharingCoordinator(
            cloudKitManager: cloudKitManager,
            loadRegisteredPeerRecord: {
                await tracker.noteLoadedPeerRecord(recordID: peerRecord.recordID)
                return peerRecord
            },
            fetchRecord: { recordID in
                await tracker.noteFetchedRecord(recordID: recordID)
                Issue.record("Unexpected share fetch for \(recordID.recordName)")
                return peerRecord
            },
            saveRecords: { records in
                await tracker.noteSavedRecords(records)
                let savedShare = try #require(records.compactMap { $0 as? CKShare }.first)
                return [
                    peerRecord.recordID: .success(peerRecord),
                    savedShare.recordID: .success(savedShare),
                ]
            }
        )

        let share = try await coordinator.ensureShare()
        let savedRecordNames = await tracker.savedRecordNames()

        #expect(await tracker.loadedPeerRecordNames() == [peerRecord.recordID.recordName])
        #expect(savedRecordNames.contains(peerRecord.recordID.recordName))
        #expect(savedRecordNames.contains(share.recordID.recordName))
        #expect(coordinator.hasPeerRecord)
        #expect(coordinator.activeShare?.recordID.recordName == share.recordID.recordName)
    }

    @MainActor
    @Test("refresh loads an existing share by exact share record ID")
    func refreshLoadsAnExistingShareByExactShareRecordID() async {
        let configuration = MirageKit.makeCloudKitConfiguration(
            containerIdentifier: "iCloud.com.ethanlipnik.Mirage"
        )
        let cloudKitManager = LoomCloudKitManager(configuration: configuration)
        let peerRecord = makePeerRecord(configuration: configuration, recordName: "peer-record")
        let existingShare = CKShare(rootRecord: peerRecord)
        let tracker = CloudKitSharingTracker()
        let coordinator = MirageHostCloudKitSharingCoordinator(
            cloudKitManager: cloudKitManager,
            loadRegisteredPeerRecord: {
                await tracker.noteLoadedPeerRecord(recordID: peerRecord.recordID)
                return peerRecord
            },
            fetchRecord: { recordID in
                await tracker.noteFetchedRecord(recordID: recordID)
                return existingShare
            },
            saveRecords: { records in
                await tracker.noteSavedRecords(records)
                return [:]
            }
        )

        await coordinator.refresh()

        #expect(await tracker.loadedPeerRecordNames() == [peerRecord.recordID.recordName])
        #expect(await tracker.fetchedRecordNames() == [existingShare.recordID.recordName])
        #expect(coordinator.hasPeerRecord)
        #expect(coordinator.activeShare?.recordID.recordName == existingShare.recordID.recordName)
    }

    private func makePeerRecord(
        configuration: LoomCloudKitConfiguration,
        recordName: String
    ) -> CKRecord {
        let zoneID = CKRecordZone.ID(
            zoneName: configuration.peerZoneName,
            ownerName: CKCurrentUserDefaultName
        )
        let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
        let record = CKRecord(
            recordType: configuration.peerRecordType,
            recordID: recordID
        )
        record[LoomCloudKitPeerInfo.RecordKey.deviceID.rawValue] = UUID().uuidString
        record[LoomCloudKitPeerInfo.RecordKey.name.rawValue] = "Test Mac"
        return record
    }
}

private actor CloudKitSharingTracker {
    private var loadedPeerRecordStorage: [String] = []
    private var fetchedRecordStorage: [String] = []
    private var savedRecordStorage: [String] = []

    func noteLoadedPeerRecord(recordID: CKRecord.ID) {
        loadedPeerRecordStorage.append(recordID.recordName)
    }

    func noteFetchedRecord(recordID: CKRecord.ID) {
        fetchedRecordStorage.append(recordID.recordName)
    }

    func noteSavedRecords(_ records: [CKRecord]) {
        savedRecordStorage.append(contentsOf: records.map(\.recordID.recordName))
    }

    func loadedPeerRecordNames() -> [String] {
        loadedPeerRecordStorage
    }

    func fetchedRecordNames() -> [String] {
        fetchedRecordStorage
    }

    func savedRecordNames() -> [String] {
        savedRecordStorage
    }
}
