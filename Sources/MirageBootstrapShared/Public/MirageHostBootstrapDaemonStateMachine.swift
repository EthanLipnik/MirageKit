//
//  MirageHostBootstrapDaemonStateMachine.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/10/26.
//

import Foundation

#if os(macOS)

public enum MirageHostBootstrapDaemonState: String, Sendable {
    case idle
    case listening
    case active
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

    public mutating func markActive() throws {
        try transition(to: .active)
    }

    private static let allowedTransitions: [MirageHostBootstrapDaemonState: Set<MirageHostBootstrapDaemonState>] = [
        .idle: [.listening],
        .listening: [.active],
    ]
}

#endif
