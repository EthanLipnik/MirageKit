//
//  MirageIncomingMediaStream+Loom.swift
//  MirageConnectivity
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation
import Loom

package protocol MirageIncomingMediaStream: Sendable {
    var incomingBytes: AsyncStream<Data> { get }

    func setIncomingBytesImmediateBatchHandler(
        maxBatchSize: Int,
        handler: @escaping @Sendable ([Data]) -> Void
    )

    func clearIncomingBytesBatchHandler()
}

extension LoomMultiplexedStream: MirageIncomingMediaStream {}
