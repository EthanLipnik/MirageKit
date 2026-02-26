//
//  MirageDiagnostics.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/23/26.
//
//  Public diagnostics reporting primitives for host app integrations.
//

import Foundation

public enum MirageDiagnosticsValue: Sendable, Equatable {
    case string(String)
    case bool(Bool)
    case int(Int)
    case double(Double)
    case array([MirageDiagnosticsValue])
    case dictionary([String: MirageDiagnosticsValue])
    case null

    public var foundationValue: Any {
        switch self {
        case let .string(value):
            value
        case let .bool(value):
            value
        case let .int(value):
            value
        case let .double(value):
            value
        case let .array(values):
            values.map(\.foundationValue)
        case let .dictionary(values):
            values.mapValues(\.foundationValue)
        case .null:
            NSNull()
        }
    }
}

public typealias MirageDiagnosticsContext = [String: MirageDiagnosticsValue]

public struct MirageDiagnosticsSinkToken: Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct MirageDiagnosticsContextProviderToken: Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct MirageDiagnosticsLogEvent: Sendable {
    public let date: Date
    public let category: LogCategory
    public let level: MirageLogLevel
    public let message: String
    public let fileID: String
    public let line: UInt
    public let function: String

    public init(
        date: Date,
        category: LogCategory,
        level: MirageLogLevel,
        message: String,
        fileID: String,
        line: UInt,
        function: String
    ) {
        self.date = date
        self.category = category
        self.level = level
        self.message = message
        self.fileID = fileID
        self.line = line
        self.function = function
    }
}

public enum MirageDiagnosticsErrorSeverity: String, Sendable {
    case error
    case fault
}

public enum MirageDiagnosticsErrorSource: String, Sendable {
    case logger
    case report
    case run
}

public struct MirageDiagnosticsErrorMetadata: Sendable, Equatable {
    public let typeName: String
    public let domain: String
    public let code: Int

    public init(typeName: String, domain: String, code: Int) {
        self.typeName = typeName
        self.domain = domain
        self.code = code
    }

    public init(error: Error) {
        let nsError = error as NSError
        self.init(
            typeName: String(reflecting: type(of: error)),
            domain: nsError.domain,
            code: nsError.code
        )
    }
}

public struct MirageDiagnosticsErrorEvent: Sendable {
    public let date: Date
    public let category: LogCategory
    public let severity: MirageDiagnosticsErrorSeverity
    public let source: MirageDiagnosticsErrorSource
    public let message: String
    public let fileID: String
    public let line: UInt
    public let function: String
    public let metadata: MirageDiagnosticsErrorMetadata?

    public init(
        date: Date,
        category: LogCategory,
        severity: MirageDiagnosticsErrorSeverity,
        source: MirageDiagnosticsErrorSource,
        message: String,
        fileID: String,
        line: UInt,
        function: String,
        metadata: MirageDiagnosticsErrorMetadata?
    ) {
        self.date = date
        self.category = category
        self.severity = severity
        self.source = source
        self.message = message
        self.fileID = fileID
        self.line = line
        self.function = function
        self.metadata = metadata
    }
}

public protocol MirageDiagnosticsSink: Sendable {
    func record(log event: MirageDiagnosticsLogEvent) async
    func record(error event: MirageDiagnosticsErrorEvent) async
}

public extension MirageDiagnosticsSink {
    func record(log _: MirageDiagnosticsLogEvent) async {}
    func record(error _: MirageDiagnosticsErrorEvent) async {}
}

public typealias MirageDiagnosticsContextProvider = @Sendable () async -> MirageDiagnosticsContext

actor MirageDiagnosticsStore {
    static let shared = MirageDiagnosticsStore()

    private var sinks: [MirageDiagnosticsSinkToken: any MirageDiagnosticsSink] = [:]
    private var contextProviders: [MirageDiagnosticsContextProviderToken: MirageDiagnosticsContextProvider] = [:]

    func addSink(_ sink: any MirageDiagnosticsSink) -> MirageDiagnosticsSinkToken {
        let token = MirageDiagnosticsSinkToken()
        sinks[token] = sink
        return token
    }

    func removeSink(_ token: MirageDiagnosticsSinkToken) {
        sinks.removeValue(forKey: token)
    }

    func removeAllSinks() {
        sinks.removeAll()
    }

    func registerContextProvider(_ provider: @escaping MirageDiagnosticsContextProvider) -> MirageDiagnosticsContextProviderToken {
        let token = MirageDiagnosticsContextProviderToken()
        contextProviders[token] = provider
        return token
    }

    func unregisterContextProvider(_ token: MirageDiagnosticsContextProviderToken) {
        contextProviders.removeValue(forKey: token)
    }

    func snapshotContext() async -> MirageDiagnosticsContext {
        var snapshot: MirageDiagnosticsContext = [:]
        let providers = Array(contextProviders.values)
        for provider in providers {
            let context = await provider()
            snapshot.merge(context, uniquingKeysWith: { _, newValue in newValue })
        }
        return snapshot
    }

    func record(log event: MirageDiagnosticsLogEvent) async {
        let sinks = Array(sinks.values)
        for sink in sinks {
            await sink.record(log: event)
        }
    }

    func record(error event: MirageDiagnosticsErrorEvent) async {
        let sinks = Array(sinks.values)
        for sink in sinks {
            await sink.record(error: event)
        }
    }
}

public enum MirageDiagnostics {
    @discardableResult
    public static func addSink(_ sink: any MirageDiagnosticsSink) async -> MirageDiagnosticsSinkToken {
        await MirageDiagnosticsStore.shared.addSink(sink)
    }

    public static func removeSink(_ token: MirageDiagnosticsSinkToken) async {
        await MirageDiagnosticsStore.shared.removeSink(token)
    }

    public static func removeAllSinks() async {
        await MirageDiagnosticsStore.shared.removeAllSinks()
    }

    @discardableResult
    public static func registerContextProvider(
        _ provider: @escaping MirageDiagnosticsContextProvider
    ) async -> MirageDiagnosticsContextProviderToken {
        await MirageDiagnosticsStore.shared.registerContextProvider(provider)
    }

    public static func unregisterContextProvider(_ token: MirageDiagnosticsContextProviderToken) async {
        await MirageDiagnosticsStore.shared.unregisterContextProvider(token)
    }

    public static func snapshotContext() async -> MirageDiagnosticsContext {
        await MirageDiagnosticsStore.shared.snapshotContext()
    }

    public static func report(
        error: Error,
        category: LogCategory,
        severity: MirageDiagnosticsErrorSeverity = .error,
        source: MirageDiagnosticsErrorSource = .report,
        message: String? = nil,
        fileID: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) {
        let metadata = MirageDiagnosticsErrorMetadata(error: error)
        let renderedMessage = message?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackMessage =
            "[\(fileID):\(line) \(function)] type=\(metadata.typeName) domain=\(metadata.domain) code=\(metadata.code)"
        let event = MirageDiagnosticsErrorEvent(
            date: Date(),
            category: category,
            severity: severity,
            source: source,
            message: (renderedMessage?.isEmpty == false ? renderedMessage : nil) ?? fallbackMessage,
            fileID: fileID,
            line: line,
            function: function,
            metadata: metadata
        )
        record(error: event)
    }

    public static func run<T>(
        category: LogCategory,
        message: String? = nil,
        fileID: String = #fileID,
        line: UInt = #line,
        function: String = #function,
        _ operation: @escaping () async throws -> T
    ) async throws -> T {
        do {
            return try await operation()
        } catch {
            report(
                error: error,
                category: category,
                source: .run,
                message: message,
                fileID: fileID,
                line: line,
                function: function
            )
            throw error
        }
    }

    public static func record(log event: MirageDiagnosticsLogEvent) {
        if Task.isCancelled { return }
        Task {
            await MirageDiagnosticsStore.shared.record(log: event)
        }
    }

    public static func record(error event: MirageDiagnosticsErrorEvent) {
        if Task.isCancelled { return }
        Task {
            await MirageDiagnosticsStore.shared.record(error: event)
        }
    }
}
