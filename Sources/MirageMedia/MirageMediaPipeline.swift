//
//  MirageMediaPipeline.swift
//  MirageMedia
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation
import MirageCore

/// Media timeline timestamp expressed in seconds.
public struct MiragePresentationTime: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: Double

    public init(rawValue: Double) {
        self.rawValue = max(0, rawValue)
    }

    public init(seconds: Double) {
        self.init(rawValue: seconds)
    }
}

/// Render deadline expressed in the same media-time domain as presentation timestamps.
public struct MiragePresentationDeadline: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: Double

    public init(rawValue: Double) {
        self.rawValue = max(0, rawValue)
    }

    public init(seconds: Double) {
        self.init(rawValue: seconds)
    }
}

/// Dependency type for one encoded media unit.
public enum MirageMediaDependency: String, CaseIterable, Codable, Sendable {
    /// Unit can be decoded without previous frames.
    case keyframe
    /// Unit depends on prior decoded media in the same dependency scope.
    case predicted
    /// Dependency is not known to the media abstraction.
    case unknown
}

/// Encoded media payload for one topology unit.
public struct MirageEncodedMediaUnit: Equatable, Codable, Sendable {
    public let streamID: StreamID
    public let topologyID: MirageMediaTopologyID
    public let mediaUnitID: MirageMediaUnitID
    public let unitFrameNumber: UInt32
    public let presentationTime: MiragePresentationTime
    public let dependency: MirageMediaDependency
    public let payload: Data

    public init(
        streamID: StreamID,
        topologyID: MirageMediaTopologyID,
        mediaUnitID: MirageMediaUnitID,
        unitFrameNumber: UInt32,
        presentationTime: MiragePresentationTime,
        dependency: MirageMediaDependency,
        payload: Data
    ) {
        self.streamID = streamID
        self.topologyID = topologyID
        self.mediaUnitID = mediaUnitID
        self.unitFrameNumber = unitFrameNumber
        self.presentationTime = presentationTime
        self.dependency = dependency
        self.payload = payload
    }
}

/// Encoded output from one encode graph invocation.
public struct MirageEncodedMediaBatch: Equatable, Codable, Sendable {
    public let streamID: StreamID
    public let topologyID: MirageMediaTopologyID
    public let units: [MirageEncodedMediaUnit]

    public init(streamID: StreamID, topologyID: MirageMediaTopologyID, units: [MirageEncodedMediaUnit]) {
        self.streamID = streamID
        self.topologyID = topologyID
        self.units = units.filter {
            $0.streamID == streamID && $0.topologyID == topologyID
        }
    }

    public var isEmpty: Bool {
        units.isEmpty
    }
}

/// Packetizer input centered on one encoded media unit.
public struct MiragePacketizerInput: Equatable, Codable, Sendable {
    public let unit: MirageEncodedMediaUnit
    public let maximumPayloadBytes: Int

    public init(unit: MirageEncodedMediaUnit, maximumPayloadBytes: Int) {
        self.unit = unit
        self.maximumPayloadBytes = max(1, maximumPayloadBytes)
    }

    public var payloadByteCount: Int {
        unit.payload.count
    }
}

/// Recovery cause carried by topology-scoped recovery requests.
public enum MirageRecoveryCause: String, CaseIterable, Codable, Sendable {
    case startup
    case keyframeLoss
    case presentationStall
    case resize
    case manual
}

/// Scope for media recovery work.
public struct MirageRecoveryScope: Hashable, Codable, Sendable {
    public let streamID: StreamID
    public let topologyID: MirageMediaTopologyID?
    public let mediaUnitID: MirageMediaUnitID?

    public init(
        streamID: StreamID,
        topologyID: MirageMediaTopologyID? = nil,
        mediaUnitID: MirageMediaUnitID? = nil
    ) {
        self.streamID = streamID
        self.topologyID = topologyID
        self.mediaUnitID = mediaUnitID
    }

    public static func fullStream(_ streamID: StreamID) -> MirageRecoveryScope {
        MirageRecoveryScope(streamID: streamID)
    }

    public var isUnitScoped: Bool {
        topologyID != nil && mediaUnitID != nil
    }
}

/// Host/client recovery request attached to a concrete media scope.
public struct MirageRecoveryRequest: Hashable, Codable, Sendable {
    public let scope: MirageRecoveryScope
    public let cause: MirageRecoveryCause

    public init(scope: MirageRecoveryScope, cause: MirageRecoveryCause) {
        self.scope = scope
        self.cause = cause
    }
}

/// Decode queue budget for topology-aware client pipelines.
public struct MirageDecodeBudgetPolicy: Hashable, Codable, Sendable {
    public let maximumQueuedFrames: Int
    public let maximumInFlightSubmissions: Int

    public init(maximumQueuedFrames: Int, maximumInFlightSubmissions: Int) {
        self.maximumQueuedFrames = max(1, maximumQueuedFrames)
        self.maximumInFlightSubmissions = max(1, maximumInFlightSubmissions)
    }
}

/// Metadata required from media packets before topology-aware decoding.
public protocol MirageMediaPacket: Sendable {
    var streamID: StreamID { get }
    var topologyID: MirageMediaTopologyID? { get }
    var mediaUnitID: MirageMediaUnitID? { get }
    var frameNumber: UInt32 { get }
}

/// Metadata required from decoded units before topology-aware composition.
public protocol MirageDecodedMediaUnit: Sendable {
    var streamID: StreamID { get }
    var topologyID: MirageMediaTopologyID { get }
    var mediaUnitID: MirageMediaUnitID { get }
    var unitFrameNumber: UInt32 { get }
    var presentationTime: MiragePresentationTime { get }
}

/// Host-side media pipeline contract.
public protocol MirageHostMediaPipeline: Sendable {
    associatedtype CapturedFrame: Sendable

    func start() async throws
    func submit(_ frame: CapturedFrame) async
    func requestRecovery(_ request: MirageRecoveryRequest) async
    func stop() async
}

/// Host encode graph contract.
public protocol MirageEncodeGraph: Sendable {
    associatedtype EncodeWork: Sendable

    func encode(_ work: EncodeWork) async throws -> MirageEncodedMediaBatch
}

/// Client-side media pipeline contract.
public protocol MirageClientMediaPipeline: Sendable {
    associatedtype Packet: MirageMediaPacket

    func processPacket(_ packet: Packet) async
    func updateTopology(_ topology: MirageMediaTopology) async
    func requestRecovery(_ scope: MirageRecoveryScope) async
    func stop() async
}

/// Client-side render compositor contract.
public protocol MirageRenderCompositor: Sendable {
    associatedtype DecodedUnit: MirageDecodedMediaUnit
    associatedtype PresentationFrame: Sendable

    func update(_ unit: DecodedUnit) async
    func render(at deadline: MiragePresentationDeadline) async -> PresentationFrame?
}
