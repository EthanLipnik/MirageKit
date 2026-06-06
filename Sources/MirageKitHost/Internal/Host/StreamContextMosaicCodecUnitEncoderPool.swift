//
//  StreamContextMosaicCodecUnitEncoderPool.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/6/26.
//

import Foundation
import MirageKit
import MirageMedia

#if os(macOS)

actor StreamContextMosaicCodecUnitEncoderPool {
    struct Key: Hashable, Sendable {
        let planID: UUID
        let planEpoch: UInt32
        let mediaUnitID: MirageMosaicCodecUnitID
        let encodedSize: MiragePixelSize
        let codec: MirageVideoCodec

        init(unit: StreamContextMosaicMediaUnitWorkItem) {
            planID = unit.plan.id.rawValue
            planEpoch = unit.plan.epoch
            mediaUnitID = unit.codecUnit.id
            encodedSize = unit.codecUnit.encodedSize
            codec = unit.codecUnit.codec
        }
    }

    struct PreparedUnit: Sendable {
        let workItem: StreamContextMosaicMediaUnitWorkItem
        let encoder: VideoEncoder
    }

    struct Snapshot: Equatable, Sendable {
        let keys: [Key]
    }

    private struct Entry: Sendable {
        let key: Key
        let encoder: VideoEncoder
    }

    private var entriesByKey: [Key: Entry] = [:]

    func synchronize(
        units: [StreamContextMosaicMediaUnitWorkItem],
        configuration: MirageEncoderConfiguration,
        latencyMode: MirageStreamLatencyMode,
        mediaPathProfile: MirageMediaPathProfile,
        inFlightLimit: Int,
        maximizePowerEfficiencyEnabled: Bool,
        factory: any MirageHostVideoEncoderFactoryBackend,
        createSessions: Bool = true,
        preheatSessions: Bool = true
    ) async throws -> [PreparedUnit] {
        let desiredKeys = Set(units.map(Key.init(unit:)))
        let staleKeys = Set(entriesByKey.keys).subtracting(desiredKeys)
        for key in staleKeys {
            if let entry = entriesByKey.removeValue(forKey: key) {
                await entry.encoder.stopEncoding()
            }
        }

        var preparedUnits: [PreparedUnit] = []
        preparedUnits.reserveCapacity(units.count)
        for unit in units {
            let key = Key(unit: unit)
            let entry: Entry
            if let existing = entriesByKey[key] {
                entry = existing
            } else {
                let encoder = factory.makeVideoEncoder(
                    configuration: encoderConfiguration(configuration, for: unit),
                    latencyMode: latencyMode,
                    streamKind: .desktop,
                    mediaPathProfile: mediaPathProfile,
                    inFlightLimit: inFlightLimit,
                    maximizePowerEfficiencyEnabled: maximizePowerEfficiencyEnabled
                )
                if createSessions {
                    try await encoder.createSession(
                        width: unit.codecUnit.encodedSize.width,
                        height: unit.codecUnit.encodedSize.height
                    )
                    if preheatSessions {
                        _ = try await encoder.preheatWithFallback()
                    }
                }
                entry = Entry(key: key, encoder: encoder)
                entriesByKey[key] = entry
            }
            preparedUnits.append(PreparedUnit(workItem: unit, encoder: entry.encoder))
        }
        return preparedUnits
    }

    func stopAll() async {
        let entries = Array(entriesByKey.values)
        entriesByKey.removeAll(keepingCapacity: false)
        for entry in entries {
            await entry.encoder.stopEncoding()
        }
    }

    var snapshot: Snapshot {
        Snapshot(keys: entriesByKey.keys.sorted { lhs, rhs in
            if lhs.planID != rhs.planID { return lhs.planID.uuidString < rhs.planID.uuidString }
            if lhs.planEpoch != rhs.planEpoch { return lhs.planEpoch < rhs.planEpoch }
            return lhs.mediaUnitID < rhs.mediaUnitID
        })
    }

    private func encoderConfiguration(
        _ configuration: MirageEncoderConfiguration,
        for unit: StreamContextMosaicMediaUnitWorkItem
    ) -> MirageEncoderConfiguration {
        var unitConfiguration = configuration
        unitConfiguration.codec = unit.codecUnit.codec
        return unitConfiguration
    }
}

#endif
