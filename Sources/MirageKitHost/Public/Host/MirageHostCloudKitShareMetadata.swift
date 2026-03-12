//
//  MirageHostCloudKitShareMetadata.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/11/26.
//

#if os(macOS)
import CloudKit
import Foundation
import MirageKit

public enum MirageHostCloudKitShareMetadata {
    private static let shareThumbnailMaxPixelSize = 512
    private static let shareThumbnailCompressionQuality = 0.35

    public nonisolated static func thumbnailData(for record: CKRecord) -> Data? {
        MainActor.assumeIsolated {
            guard
                let advertisementBlob = record[LoomCloudKitPeerInfo.RecordKey.advertisementBlob.rawValue] as? Data,
                let advertisement = try? JSONDecoder().decode(LoomPeerAdvertisement.self, from: advertisementBlob)
            else {
                return nil
            }

            return MirageHostHardwareIconResolver.cloudKitShareThumbnailData(
                preferredIconName: advertisement.iconName,
                hardwareMachineFamily: advertisement.machineFamily,
                hardwareModelIdentifier: advertisement.modelIdentifier,
                maxPixelSize: shareThumbnailMaxPixelSize,
                compressionQuality: shareThumbnailCompressionQuality
            )
        }
    }
}
#endif
