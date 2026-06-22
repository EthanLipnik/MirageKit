//
//  MirageDiagnostics.MirageDiagnosticsSubmissionPolicy+Loom.swift
//  MirageConnectivity
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Loom
import MirageDiagnostics

public extension MirageDiagnostics.MirageDiagnosticsSubmissionPolicy {
    /// Returns the submission classification tags for a Loom diagnostics error event.
    static func classification(for event: LoomDiagnosticsErrorEvent) -> MirageDiagnostics.MirageDiagnosticsEventClassification {
        classification(for: MirageDiagnostics.MirageDiagnosticsErrorEventSnapshot(loomEvent: event))
    }
}

private extension MirageDiagnostics.MirageDiagnosticsErrorEventSnapshot {
    init(loomEvent event: LoomDiagnosticsErrorEvent) {
        self.init(
            category: event.category.rawValue,
            severity: MirageDiagnostics.MirageDiagnosticsErrorSeverity(loomSeverity: event.severity),
            message: event.message,
            metadata: event.metadata.map(MirageDiagnostics.MirageDiagnosticsErrorMetadata.init(loomMetadata:))
        )
    }
}

private extension MirageDiagnostics.MirageDiagnosticsErrorMetadata {
    init(loomMetadata metadata: LoomDiagnosticsErrorMetadata) {
        self.init(
            typeName: metadata.typeName,
            domain: metadata.domain,
            code: metadata.code
        )
    }
}

private extension MirageDiagnostics.MirageDiagnosticsErrorSeverity {
    init(loomSeverity severity: LoomDiagnosticsErrorSeverity) {
        switch severity {
        case .error:
            self = .error
        case .fault:
            self = .fault
        }
    }
}
