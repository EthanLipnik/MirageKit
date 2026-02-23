//
//  MirageHostBootstrapDaemonStateMachine.swift
//  MirageKit
//
//  Created by Codex on 2/21/26.
//
//  Deterministic state transitions for host bootstrap daemon lifecycle.
//

import Foundation

#if os(macOS)

public enum MirageHostBootstrapDaemonState: String, Sendable {
    case idle
    case listening
    case unlocking
    case active
    case stopped
}

public enum MirageHostBootstrapDaemonStateMachineError: LocalizedError, Sendable {
    case invalidTransition(from: MirageHostBootstrapDaemonState, to: MirageHostBootstrapDaemonState)

    public var errorDescription: String? {
        switch self {
        case let .invalidTransition(from, to):
            "Invalid bootstrap daemon transition: \(from.rawValue) -> \(to.rawValue)"
        }
    }
}

public struct MirageHostBootstrapDaemonStateMachine: Sendable, Equatable {
    public private(set) var state: MirageHostBootstrapDaemonState

    public init(initialState: MirageHostBootstrapDaemonState = .idle) {
        state = initialState
    }

    public mutating func transition(to nextState: MirageHostBootstrapDaemonState) throws {
        if state == nextState { return }
        guard Self.allowedTransitions[state, default: []].contains(nextState) else {
            throw MirageHostBootstrapDaemonStateMachineError.invalidTransition(from: state, to: nextState)
        }
        state = nextState
    }

    public mutating func markListening() throws {
        try transition(to: .listening)
    }

    public mutating func markUnlocking() throws {
        try transition(to: .unlocking)
    }

    public mutating func markActive() throws {
        try transition(to: .active)
    }

    public mutating func markStopped() throws {
        try transition(to: .stopped)
    }

    private static let allowedTransitions: [MirageHostBootstrapDaemonState: Set<MirageHostBootstrapDaemonState>] = [
        .idle: [.listening, .stopped],
        .listening: [.unlocking, .active, .stopped],
        .unlocking: [.listening, .active, .stopped],
        .active: [.stopped],
        .stopped: [.listening],
    ]
}

#endif
