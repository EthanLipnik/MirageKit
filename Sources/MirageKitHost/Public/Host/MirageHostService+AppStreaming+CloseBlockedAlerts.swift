//
//  MirageHostService+AppStreaming+CloseBlockedAlerts.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/28/26.
//
//  Host-side close-attempt + actionable alert routing for client window close events.
//

import Foundation
import MirageKit

#if os(macOS)

@MainActor
extension MirageHostService {
    enum ClientWindowCloseHostWindowCloseDecision: Equatable, Sendable {
        case attemptHostWindowClose
        case skipOriginNotClientWindowClosed
        case skipSettingDisabled
        case skipNoAppStreamSession
    }

    nonisolated static func clientWindowCloseHostWindowCloseDecision(
        origin: StopStreamMessage.Origin?,
        closeHostWindowOnClientWindowClose: Bool,
        hasAppStreamSession: Bool
    ) -> ClientWindowCloseHostWindowCloseDecision {
        guard origin == .clientWindowClosed else {
            return .skipOriginNotClientWindowClosed
        }
        guard closeHostWindowOnClientWindowClose else {
            return .skipSettingDisabled
        }
        guard hasAppStreamSession else {
            return .skipNoAppStreamSession
        }
        return .attemptHostWindowClose
    }

    nonisolated static func appWindowCloseAlertPresentingStreamID(
        activeStreams: [MirageStreamSession],
        clientID: UUID,
        excludingStreamID: StreamID
    ) -> StreamID? {
        activeStreams
            .filter { stream in
                stream.client.id == clientID &&
                    stream.id != excludingStreamID &&
                    stream.window.id != 0
            }
            .sorted { lhs, rhs in
                if lhs.id != rhs.id {
                    return lhs.id < rhs.id
                }
                return lhs.window.id < rhs.window.id
            }
            .first?
            .id
    }

    func handleHostWindowCloseAttemptForClientWindowClose(
        session: MirageStreamSession,
        appSession: MirageAppStreamSession
    ) async {
        let closeResult = await inputController.attemptCloseWindowAndExtractBlockingAlert(
            windowID: session.window.id,
            app: session.window.application
        )

        switch closeResult {
        case .closed:
            MirageLogger.host(
                "Closed host window \(session.window.id) after client closed stream window (bundle=\(appSession.bundleIdentifier))"
            )
        case let .blocked(alert):
            await emitCloseBlockedAlertIfPossible(
                session: session,
                appSession: appSession,
                alert: alert
            )
        case .notClosed:
            break
        }
    }

    func performAppWindowCloseAlertAction(
        alertToken: String,
        actionID: String,
        presentingStreamID: StreamID,
        clientID: UUID
    ) async -> AppWindowCloseAlertActionResultMessage {
        let token = alertToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            return AppWindowCloseAlertActionResultMessage(
                alertToken: alertToken,
                actionID: actionID,
                success: false,
                reason: "Alert token is empty"
            )
        }

        guard let pending = pendingAppWindowCloseAlertTokensByToken[token] else {
            return AppWindowCloseAlertActionResultMessage(
                alertToken: alertToken,
                actionID: actionID,
                success: false,
                reason: "Alert token expired"
            )
        }

        guard pending.clientID == clientID else {
            return AppWindowCloseAlertActionResultMessage(
                alertToken: alertToken,
                actionID: actionID,
                success: false,
                reason: "Alert token does not belong to this client"
            )
        }

        guard pending.presentingStreamID == presentingStreamID else {
            return AppWindowCloseAlertActionResultMessage(
                alertToken: alertToken,
                actionID: actionID,
                success: false,
                reason: "Presenting stream mismatch"
            )
        }

        guard activeStreams.contains(where: { $0.id == presentingStreamID && $0.client.id == clientID }) else {
            return AppWindowCloseAlertActionResultMessage(
                alertToken: alertToken,
                actionID: actionID,
                success: false,
                reason: "Presenting stream is no longer active"
            )
        }

        guard let action = pending.actions.first(where: { $0.id == actionID }) else {
            return AppWindowCloseAlertActionResultMessage(
                alertToken: alertToken,
                actionID: actionID,
                success: false,
                reason: "Requested alert action is unavailable"
            )
        }

        let pressed = await inputController.pressBlockingAlertAction(
            windowID: pending.sourceWindowID,
            app: pending.sourceApp,
            actionIndex: action.index,
            fallbackTitle: action.title
        )
        guard pressed else {
            return AppWindowCloseAlertActionResultMessage(
                alertToken: alertToken,
                actionID: actionID,
                success: false,
                reason: "Failed to perform host alert action"
            )
        }

        clearPendingAppWindowCloseAlertToken(token)
        return AppWindowCloseAlertActionResultMessage(
            alertToken: alertToken,
            actionID: actionID,
            success: true,
            reason: nil
        )
    }

    func clearPendingAppWindowCloseAlertToken(_ token: String) {
        pendingAppWindowCloseAlertTokensByToken.removeValue(forKey: token)
    }

    func clearPendingAppWindowCloseAlertTokens(forClientID clientID: UUID) {
        pendingAppWindowCloseAlertTokensByToken = pendingAppWindowCloseAlertTokensByToken.filter { _, value in
            value.clientID != clientID
        }
    }

    func clearAllPendingAppWindowCloseAlertTokens() {
        pendingAppWindowCloseAlertTokensByToken.removeAll()
    }

    private func clearPendingAppWindowCloseAlertTokens(
        forClientID clientID: UUID,
        sourceWindowID: WindowID
    ) {
        pendingAppWindowCloseAlertTokensByToken = pendingAppWindowCloseAlertTokensByToken.filter { _, value in
            !(value.clientID == clientID && value.sourceWindowID == sourceWindowID)
        }
    }

    private func emitCloseBlockedAlertIfPossible(
        session: MirageStreamSession,
        appSession: MirageAppStreamSession,
        alert: HostWindowCloseAlertSnapshot
    ) async {
        guard let presentingStreamID = Self.appWindowCloseAlertPresentingStreamID(
            activeStreams: activeStreams,
            clientID: session.client.id,
            excludingStreamID: session.id
        ) else {
            return
        }

        guard let clientContext = findClientContext(clientID: session.client.id) else {
            return
        }

        let mappedActions = alert.actions.map { action in
            let id = "action-\(action.index)"
            return PendingAppWindowCloseAlertAction(
                id: id,
                title: action.title,
                isDestructive: action.isDestructive,
                index: action.index
            )
        }
        guard !mappedActions.isEmpty else { return }

        let token = UUID().uuidString.lowercased()
        clearPendingAppWindowCloseAlertTokens(forClientID: session.client.id, sourceWindowID: session.window.id)
        pendingAppWindowCloseAlertTokensByToken[token] = PendingAppWindowCloseAlertToken(
            token: token,
            clientID: session.client.id,
            bundleIdentifier: appSession.bundleIdentifier,
            sourceWindowID: session.window.id,
            sourceApp: session.window.application,
            presentingStreamID: presentingStreamID,
            actions: mappedActions
        )

        let message = AppWindowCloseBlockedAlertMessage(
            bundleIdentifier: appSession.bundleIdentifier,
            sourceWindowID: session.window.id,
            presentingStreamID: presentingStreamID,
            alertToken: token,
            title: alert.title,
            message: alert.message,
            actions: mappedActions.map { action in
                AppWindowCloseBlockedAlertMessage.Action(
                    id: action.id,
                    title: action.title,
                    isDestructive: action.isDestructive
                )
            }
        )
        try? await clientContext.send(.appWindowCloseBlockedAlert, content: message)
    }
}

#endif
