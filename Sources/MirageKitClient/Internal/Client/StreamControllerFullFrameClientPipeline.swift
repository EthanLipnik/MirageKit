//
//  StreamControllerFullFrameClientPipeline.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/5/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import Foundation

/// Legacy full-frame packet input for the topology-aware client pipeline wrapper.
struct StreamControllerFullFrameMediaPacket: MirageMediaPacket {
    let payload: Data
    let header: MirageWire.FrameHeader
    let topologyID: MirageMediaTopologyID?
    let mediaUnitID: MirageMediaUnitID?

    var streamID: StreamID {
        header.streamID
    }

    var frameNumber: UInt32 {
        header.frameNumber
    }

    init(
        payload: Data,
        header: MirageWire.FrameHeader,
        topologyID: MirageMediaTopologyID? = nil,
        mediaUnitID: MirageMediaUnitID? = nil
    ) {
        self.payload = payload
        self.header = header
        self.topologyID = topologyID
        self.mediaUnitID = mediaUnitID
    }
}

/// Adapts the current full-frame client controller to the topology-aware media contract.
actor StreamControllerFullFrameClientPipeline: MirageClientMediaPipeline {
    private let controller: StreamController
    private var topology: MirageMediaTopology

    init(
        controller: StreamController,
        topologyID: MirageMediaTopologyID = MirageMediaTopologyID(),
        logicalSize: MiragePixelSize = MiragePixelSize(width: 0, height: 0),
        codec: MirageMedia.MirageVideoCodec = .hevc
    ) {
        self.controller = controller
        topology = MirageMediaTopology.singleUnit(
            id: topologyID,
            logicalSize: logicalSize,
            codec: codec
        )
    }

    func currentTopology() -> MirageMediaTopology {
        topology
    }

    func processPacket(_ packet: StreamControllerFullFrameMediaPacket) async {
        guard packet.streamID == controller.streamID else { return }
        guard packet.topologyID == nil || packet.topologyID == topology.id else { return }
        guard packet.mediaUnitID == nil || packet.mediaUnitID == .primary else { return }
        controller.reassembler.processPacket(packet.payload, header: packet.header)
    }

    func updateTopology(_ topology: MirageMediaTopology) async {
        guard topology.representsSingleUnitFullFrame,
              topology.units.first?.id == .primary else {
            return
        }
        self.topology = topology
    }

    func requestRecovery(_ scope: MirageRecoveryScope) async {
        guard scope.streamID == controller.streamID else { return }
        guard scope.topologyID == nil || scope.topologyID == topology.id else { return }
        guard scope.mediaUnitID == nil || scope.mediaUnitID == .primary else { return }
        await controller.requestKeyframeRecoveryIfPossible(reason: .manualRecovery)
    }

    func stop() async {
        await controller.stop()
    }
}

extension StreamController {
    nonisolated func fullFrameClientPipeline(
        topologyID: MirageMediaTopologyID = MirageMediaTopologyID(),
        logicalSize: MiragePixelSize = MiragePixelSize(width: 0, height: 0),
        codec: MirageMedia.MirageVideoCodec = .hevc
    ) -> StreamControllerFullFrameClientPipeline {
        StreamControllerFullFrameClientPipeline(
            controller: self,
            topologyID: topologyID,
            logicalSize: logicalSize,
            codec: codec
        )
    }
}
