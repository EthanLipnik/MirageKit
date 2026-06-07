//
//  MirageHostQueuedUnreliableDropCounts.swift
//  MirageDiagnostics
//
//  Created by Ethan Lipnik on 6/5/26.
//

/// Host-side Loom queued-unreliable drop counts for one metrics window.
public struct MirageHostQueuedUnreliableDropCounts: Sendable, Equatable {
    public var deadlineExpired: UInt64
    public var queueLimit: UInt64
    public var superseded: UInt64
    public var unsupportedTransport: UInt64
    public var closed: UInt64

    public init(
        deadlineExpired: UInt64 = 0,
        queueLimit: UInt64 = 0,
        superseded: UInt64 = 0,
        unsupportedTransport: UInt64 = 0,
        closed: UInt64 = 0
    ) {
        self.deadlineExpired = deadlineExpired
        self.queueLimit = queueLimit
        self.superseded = superseded
        self.unsupportedTransport = unsupportedTransport
        self.closed = closed
    }

    public var total: UInt64 {
        deadlineExpired + queueLimit + superseded + unsupportedTransport + closed
    }

    public var isEmpty: Bool {
        total == 0
    }
}
