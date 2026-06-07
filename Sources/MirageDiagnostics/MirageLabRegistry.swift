//
//  MirageLabRegistry.swift
//  MirageDiagnostics
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation

/// Executes one repeatable Lab.
@_spi(Labs)
public protocol MirageLabRunner: Sendable {
    var descriptor: MirageLabDescriptor { get }

    func run(
        _ configuration: MirageLabConfiguration,
        progress: MirageLabProgressHandler?
    ) async throws -> MirageLabReport
}

/// Errors emitted by Lab registry lookup and execution.
@_spi(Labs)
public enum MirageLabRegistryError: Error, Equatable, Sendable {
    case duplicateLabID(String)
    case unknownLabID(String)
    case unavailableLab(String)
}

/// In-memory registry for Lab runners.
@_spi(Labs)
public struct MirageLabRegistry: Sendable {
    private let runnersByID: [String: any MirageLabRunner]
    private let orderedIDs: [String]

    public init() {
        runnersByID = [:]
        orderedIDs = []
    }

    public init(runners: [any MirageLabRunner]) throws {
        var runnersByID: [String: any MirageLabRunner] = [:]
        var orderedIDs: [String] = []

        for runner in runners {
            let id = runner.descriptor.id
            guard runnersByID[id] == nil else {
                throw MirageLabRegistryError.duplicateLabID(id)
            }
            runnersByID[id] = runner
            orderedIDs.append(id)
        }

        self.runnersByID = runnersByID
        self.orderedIDs = orderedIDs
    }

    public var descriptors: [MirageLabDescriptor] {
        orderedIDs.compactMap { runnersByID[$0]?.descriptor }
    }

    public func descriptor(id: String) -> MirageLabDescriptor? {
        runnersByID[id]?.descriptor
    }

    public func runner(id: String) -> (any MirageLabRunner)? {
        runnersByID[id]
    }

    public func run(
        id: String,
        configuration: MirageLabConfiguration? = nil,
        progress: MirageLabProgressHandler? = nil
    ) async throws -> MirageLabReport {
        guard let runner = runnersByID[id] else {
            throw MirageLabRegistryError.unknownLabID(id)
        }
        guard runner.descriptor.availability.canRun else {
            throw MirageLabRegistryError.unavailableLab(id)
        }
        return try await runner.run(
            configuration ?? runner.descriptor.defaultConfiguration,
            progress: progress
        )
    }
}
