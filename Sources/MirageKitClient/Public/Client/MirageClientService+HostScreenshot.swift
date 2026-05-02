//
//  MirageClientService+HostScreenshot.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/2/26.
//
//  Client-initiated host screenshot requests.
//

import Foundation
import MirageKit

@MainActor
public extension MirageClientService {
    @discardableResult
    func requestHostScreenshot(
        style: MirageHostScreenshotStyle,
        streamID: StreamID? = nil
    ) async throws -> UUID {
        let requestID = UUID()
        let request = HostScreenshotRequestMessage(
            requestID: requestID,
            style: style,
            streamID: streamID
        )
        try await sendControlMessage(.hostScreenshotRequest, content: request)
        return requestID
    }
}
