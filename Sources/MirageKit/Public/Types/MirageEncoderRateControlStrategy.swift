//
//  MirageEncoderRateControlStrategy.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/21/26.
//

import Foundation

/// VideoToolbox rate-control policy active on the host encoder.
public enum MirageEncoderRateControlStrategy: String, Codable, Sendable, Equatable {
    /// AverageBitRate plus DataRateLimits, used for production realtime streaming.
    case averageBitRateDataRateLimits

    /// No bitrate policy is active.
    case none
}
