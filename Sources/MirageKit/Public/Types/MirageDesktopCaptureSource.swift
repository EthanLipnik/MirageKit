import Foundation

public enum MirageDesktopCaptureSource: String, Sendable, CaseIterable, Codable {
    case virtualDisplay
    case mainDisplay

    public var displayName: String {
        switch self {
        case .virtualDisplay:
            return "Virtual Display"
        case .mainDisplay:
            return "Main Display"
        }
    }
}
