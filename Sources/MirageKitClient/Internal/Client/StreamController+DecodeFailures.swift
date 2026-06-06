//
//  StreamController+DecodeFailures.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/10/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import Foundation

extension StreamController {
    /// Records a foreground decode failure and escalates logging once recovery is actionable.
    func recordDecodeFailure(_ error: Error) async {
        guard isRunning, !isStopping else { return }
        guard !hasTriggeredTerminalStartupFailure else { return }

        if await Self.shouldSuppressDecodeFailureRecovery(
            isApplicationForeground: applicationForegroundProvider()
        ) {
            recordBackgroundDecodeFailureIfNeeded(error)
            consecutiveDecodeErrors = 0
            lastDecodeErrorSignature = nil
            lastDecodeErrorLogTime = 0
            return
        }

        let metadata = MirageDiagnostics.MirageDiagnosticsErrorMetadata(error: error)
        let signature = "\(metadata.domain):\(metadata.code)"
        let now = currentTime
        consecutiveDecodeErrors += 1
        let logMessage = Self.decodeFailureLogMessage(for: error, attempt: consecutiveDecodeErrors)
        let shouldElevate = Self.shouldElevateDecodeFailure(
            consecutiveDecodeErrors: consecutiveDecodeErrors,
            signature: signature,
            previousSignature: lastDecodeErrorSignature,
            lastLogTime: lastDecodeErrorLogTime,
            now: now,
            recoveryActionable: shouldAttemptDecodeErrorRecovery(now: now)
        )

        if shouldElevate {
            MirageLogger.error(
                .client,
                error: error,
                message: logMessage
            )
            lastDecodeErrorSignature = signature
            lastDecodeErrorLogTime = now
        } else {
            let threshold = Self.decodeErrorEscalationThreshold
            if consecutiveDecodeErrors < threshold {
                MirageLogger.debug(
                    .client,
                    "Decode error observed before escalation threshold (attempt \(consecutiveDecodeErrors)/\(threshold), signature \(signature))"
                )
            } else {
                let recoveryActionable = shouldAttemptDecodeErrorRecovery(now: now)
                if recoveryActionable {
                    MirageLogger.debug(
                        .client,
                        "\(logMessage) [suppressed-repeat]"
                    )
                } else {
                    MirageLogger.debug(
                        .client,
                        "\(logMessage) [suppressed-until-recovery-actionable]"
                    )
                }
            }
        }
    }

    /// Returns whether decode-error recovery should stay suppressed while the app is not active.
    nonisolated static func shouldSuppressDecodeFailureRecovery(
        isApplicationForeground: Bool
    ) -> Bool {
        !isApplicationForeground
    }

    private func recordBackgroundDecodeFailureIfNeeded(_ error: Error) {
        let metadata = MirageDiagnostics.MirageDiagnosticsErrorMetadata(error: error)
        let signature = "\(metadata.domain):\(metadata.code)"
        let now = currentTime
        let shouldLog = signature != lastBackgroundDecodeErrorSignature ||
            now - lastBackgroundDecodeErrorLogTime >= Self.backgroundDecodeErrorLogInterval

        guard shouldLog else { return }

        lastBackgroundDecodeErrorSignature = signature
        lastBackgroundDecodeErrorLogTime = now
        MirageLogger.client(
            "Decode error while backgrounded; suppressing recovery until foreground " +
                "[\(Self.decodeFailureDiagnosticSummary(for: error))]"
        )
    }

    /// Builds the foreground decode-error log message for the current consecutive failure count.
    nonisolated static func decodeFailureLogMessage(for error: Error, attempt: Int) -> String {
        "Decode error (attempt \(attempt)): \(decodeFailureDiagnosticSummary(for: error))"
    }

    /// Produces a compact nested diagnostic summary without relying on localized formatting alone.
    nonisolated static func decodeFailureDiagnosticSummary(for error: Error) -> String {
        var components: [String] = []
        appendDiagnosticSummary(for: error, label: "error", into: &components)

        if let nsUnderlyingError = (error as NSError).userInfo[NSUnderlyingErrorKey] as? Error {
            appendDiagnosticSummary(for: nsUnderlyingError, label: "nsUnderlying", into: &components)
        }

        return components.joined(separator: " | ")
    }

    private nonisolated static func appendDiagnosticSummary(
        for error: Error,
        label: String,
        into components: inout [String]
    ) {
        let metadata = MirageDiagnostics.MirageDiagnosticsErrorMetadata(error: error)
        let localizedDescription = sanitizedDiagnosticDescription(error.localizedDescription)
        components.append(
            "\(label){type=\(metadata.typeName),domain=\(metadata.domain),code=\(metadata.code),description=\(localizedDescription)}"
        )

        if let mirageError = error as? MirageCore.MirageError {
            switch mirageError {
            case let .connectionFailed(underlyingError),
                 let .encodingError(underlyingError),
                 let .decodingError(underlyingError):
                appendNestedDiagnosticSummary(
                    for: underlyingError,
                    parentLabel: label,
                    into: &components
                )
            case let .protocolError(message):
                components.append("\(label).protocol{\(sanitizedDiagnosticDescription(message))}")
            case let .captureSetupFailed(message):
                components.append("\(label).captureSetup{\(sanitizedDiagnosticDescription(message))}")
            case let .connectionRejected(rejection):
                components.append("\(label).rejection{\(rejection.reason.rawValue)}")
            case .alreadyAdvertising,
                 .notAdvertising,
                 .authenticationFailed,
                 .streamNotFound,
                 .windowNotFound,
                 .permissionDenied,
                 .timeout:
                break
            }
        }
    }

    private nonisolated static func appendNestedDiagnosticSummary(
        for error: Error,
        parentLabel: String,
        into components: inout [String]
    ) {
        let metadata = MirageDiagnostics.MirageDiagnosticsErrorMetadata(error: error)
        let localizedDescription = sanitizedDiagnosticDescription(error.localizedDescription)
        components.append(
            "\(parentLabel).underlying{type=\(metadata.typeName),domain=\(metadata.domain),code=\(metadata.code),description=\(localizedDescription)}"
        )
    }

    private nonisolated static func sanitizedDiagnosticDescription(_ description: String) -> String {
        description
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Decides whether a decode failure should be surfaced as an elevated log and recovery signal.
    nonisolated static func shouldElevateDecodeFailure(
        consecutiveDecodeErrors: Int,
        signature: String,
        previousSignature: String?,
        lastLogTime: CFAbsoluteTime,
        now: CFAbsoluteTime,
        recoveryActionable: Bool
    ) -> Bool {
        guard recoveryActionable else { return false }
        guard consecutiveDecodeErrors >= decodeErrorEscalationThreshold else { return false }
        if consecutiveDecodeErrors == decodeErrorEscalationThreshold {
            return true
        }
        if signature != previousSignature {
            return true
        }
        return now - lastLogTime >= decodeErrorLogInterval
    }
}
