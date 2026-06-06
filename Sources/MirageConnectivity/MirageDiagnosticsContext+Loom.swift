//
//  MirageDiagnosticsContext+Loom.swift
//  MirageConnectivity
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Loom
import MirageDiagnostics

package struct MirageDiagnosticsContextProviderToken: Sendable, Hashable {
    fileprivate let loomToken: LoomDiagnosticsContextProviderToken
}

package enum MirageDiagnosticsContextRegistry {
    @discardableResult
    package static func registerContextProvider(
        _ provider: @escaping @Sendable () async -> MirageDiagnosticsContext
    ) async -> MirageDiagnosticsContextProviderToken {
        let token = await LoomDiagnostics.registerContextProvider {
            await provider().loomDiagnosticsContext
        }
        return MirageDiagnosticsContextProviderToken(loomToken: token)
    }

    package static func unregisterContextProvider(_ token: MirageDiagnosticsContextProviderToken) async {
        await LoomDiagnostics.unregisterContextProvider(token.loomToken)
    }
}

package extension Dictionary where Key == String, Value == MirageDiagnosticsValue {
    var loomDiagnosticsContext: LoomDiagnosticsContext {
        mapValues(\.loomDiagnosticsValue)
    }
}

package extension MirageDiagnosticsValue {
    var loomDiagnosticsValue: LoomDiagnosticsValue {
        switch self {
        case let .string(value):
            .string(value)
        case let .bool(value):
            .bool(value)
        case let .int(value):
            .int(value)
        case let .double(value):
            .double(value)
        case let .array(values):
            .array(values.map(\.loomDiagnosticsValue))
        case let .dictionary(values):
            .dictionary(values.loomDiagnosticsContext)
        case .null:
            .null
        }
    }
}
